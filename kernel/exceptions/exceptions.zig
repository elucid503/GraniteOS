// kernel/exceptions/exceptions.zig — Exception handlers (called from boot/vectors.S)

const uart = @import("../drivers/uart.zig");
const gic = @import("../drivers/gic.zig");
const timer = @import("../scheduler/timer.zig");
const scheduler = @import("../scheduler/scheduler.zig");

pub fn enable_interrupts() void {

    asm volatile ("msr daifclr, #0x2"); // Unmasks IRQ exceptions by clearing the I bit in DAIF

}

// Timer / device IRQ: acknowledge, handle, return (possibly different) SP.
export fn handle_irq(saved_sp: u64) u64 {

    const interrupt_id = gic.acknowledge();

    if (interrupt_id == timer.INTERRUPT_ID) {

        timer.reset();

        const new_sp = scheduler.tick(saved_sp);

        gic.end_of_interrupt(interrupt_id);

        return new_sp;

    }

    if (interrupt_id < 1020) { // Not a trusted interrupt ID — spurious or CPU-local

        gic.end_of_interrupt(interrupt_id);

    }

    return saved_sp;

}

// Catch-all for unhandled exceptions — prints diagnostics and halts.
export fn handle_unhandled(exception_syndrome: u64, faulting_address: u64) noreturn {

    uart.print("Unhandled Exception!\r\n");

    uart.print_hex(exception_syndrome);
    uart.print("\r@ ");
    uart.print_hex(faulting_address);

    uart.print("\r\n");

    while (true) {

        asm volatile ("wfe");

    }

}
