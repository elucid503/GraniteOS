// kernel/kmain.zig - Kernel entry point (EL1, MMU on via identity map)
//
// Core 0 initializes all subsystems, spawns the first user process,
// then wakes secondary cores. Each secondary core inits its own GIC
// CPU interface and timer, then enters the idle loop.

const std = @import("std");

const uart = @import("drivers/uart.zig");
const gic = @import("drivers/gic.zig");
const extio = @import("drivers/extio.zig");

const timer = @import("scheduler/timer.zig");
const scheduler = @import("scheduler/scheduler.zig");

const exceptions = @import("exceptions/exceptions.zig");

const physical_allocator = @import("memory/physical_allocator.zig");
const heap = @import("memory/heap.zig");

const process = @import("process/process.zig");
const fs = @import("fs/fs.zig");
const persist = @import("fs/persist.zig");

const user_programs = @import("user_programs"); // generated at compile time by build.zig

/// Secondary core entry point (defined in start.S). Used as the PSCI CPU_ON target.
extern const secondary_entry: u8;

export fn kmain() noreturn {

    uart.init();

    uart.print("Welcome to GraniteOS!\r\n\r\n");

    uart.print("Memory Management Unit ......... Enabled\r\n");

    physical_allocator.init();
    uart.print("Physical Memory ......... Initialized\r\n");

    heap.init(16);
    uart.print("Kernel Heap ......... Initialized\r\n");

    fs.init();
    uart.print("File System ......... Initialized\r\n");

    // Try to load persistent FS from disk (if virtio-blk is present)

    if (extio.init()) {

        uart.print("ExtIO ......... Initialized\r\n");

        if (persist.load()) {

            uart.print("Persistent FS ......... Loaded\r\n");

        } else {

            // First boot or invalid disk - save defaults
            persist.save_all();
            uart.print("Persistent FS ......... Created\r\n");

        }

    } else {

        uart.print("ExtIO ......... Not available\r\n");

    }

    gic.init();
    uart.print("GIC ......... Initialized\r\n");

    timer.init();
    uart.print("Timer ......... Set to 100ms\r\n");

    scheduler.init();

    // Spawn SLATE (System Launch And Task Executor) as the first user process.

    for (user_programs.programs) |prog| {

        if (std.mem.eql(u8, prog.name, "slate")) {

            process.spawn_elf(prog.elf);
            break;

        }

    }

    uart.print("User Programs ......... Loaded\r\n");

    // Wake secondary cores via PSCI CPU_ON (HVC conduit on QEMU virt)

    const entry_pa: u64 = @intFromPtr(&secondary_entry);

    for (1..4) |i| {
        psci_cpu_on(@intCast(i), entry_pa, @intCast(i));
    }

    uart.print("SMP ......... Cores started\r\n");

    exceptions.enable_interrupts();

    while (true) asm volatile ("wfe");

}

/// PSCI CPU_ON (64-bit): start a secondary core at the given physical entry point.
fn psci_cpu_on(target_cpu: u64, entry_point: u64, context_id: u64) void {

    const PSCI_CPU_ON_64: u64 = 0xC4000003;

    _ = asm volatile ("hvc #0"
        : [ret] "={x0}" (-> u64),
        : [fid] "{x0}" (PSCI_CPU_ON_64),
          [cpu] "{x1}" (target_cpu),
          [entry] "{x2}" (entry_point),
          [ctx] "{x3}" (context_id),
        : .{ .memory = true }
    );

}

/// Entry point for secondary cores (called from start.S after PSCI CPU_ON).
/// x0 = core ID.
export fn kmain_secondary(core_id: u64) noreturn {

    // GIC CPU interface is per-core (banked registers at same address)
    gic.init_secondary();

    // Each core has its own physical timer
    timer.init();

    // Register this core with the scheduler
    scheduler.register_core(@intCast(core_id));

    // Enable interrupts and idle
    exceptions.enable_interrupts();

    while (true) asm volatile ("wfe");

}
