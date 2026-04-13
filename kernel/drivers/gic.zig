// kernel/drivers/gic.zig - GICv2 driver (QEMU virt: distributor 0x0800_0000, CPU interface 0x0801_0000)

const distributor_control = @as(*volatile u32, @ptrFromInt(0x0800_0000 + 0x000));
const distributor_set_enable = @as(*volatile u32, @ptrFromInt(0x0800_0000 + 0x100));

const cpu_interface_control = @as(*volatile u32, @ptrFromInt(0x0801_0000 + 0x000));
const cpu_priority_mask = @as(*volatile u32, @ptrFromInt(0x0801_0000 + 0x004));
const cpu_interrupt_ack = @as(*volatile u32, @ptrFromInt(0x0801_0000 + 0x00C));
const cpu_end_of_interrupt = @as(*volatile u32, @ptrFromInt(0x0801_0000 + 0x010));

/// Full GIC init (core 0 only): distributor + CPU interface.
pub fn init() void {

    distributor_control.* = 1;
    distributor_set_enable.* = 1 << 30; // Physical timer PPI (INTID 30)
    cpu_priority_mask.* = 0xFF; // Accepts all priorities
    cpu_interface_control.* = 1;

}

/// Per-CPU interface init for secondary cores.
/// The distributor is shared and already configured by core 0.
/// Each core's CPU interface registers are banked (same address, per-core state).
pub fn init_secondary() void {

    distributor_set_enable.* = 1 << 30; // PPI 30 enable is banked per-core
    cpu_priority_mask.* = 0xFF;
    cpu_interface_control.* = 1;

}

pub fn acknowledge() u32 {

    return cpu_interrupt_ack.* & 0x3FF;

}

pub fn end_of_interrupt(interrupt_id: u32) void {

    cpu_end_of_interrupt.* = interrupt_id;

}
