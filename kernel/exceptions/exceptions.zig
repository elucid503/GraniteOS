// kernel/exceptions/exceptions.zig - EL1 exception handlers (called from boot/vectors.S)

const uart = @import("../drivers/uart.zig");
const gic = @import("../drivers/gic.zig");
const timer = @import("../scheduler/timer.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const syscall = @import("../syscall/syscall.zig");

// Force syscall module into the compilation so handle_syscall is linked.
comptime {
    _ = syscall.handle_syscall;
}

pub fn enable_interrupts() void {

    asm volatile ("msr daifclr, #0x2"); // Unmask IRQ by clearing the I bit in DAIF

}

/// Timer / device IRQ from EL1 or EL0. Acknowledge, tick the scheduler, return new SP.
export fn handle_irq(saved_sp: u64) u64 {

    const interrupt_id = gic.acknowledge();

    if (interrupt_id == timer.INTERRUPT_ID) {

        timer.reset();

        const new_sp = scheduler.tick(saved_sp);

        gic.end_of_interrupt(interrupt_id);

        return new_sp;

    }

    if (interrupt_id < 1020) {

        gic.end_of_interrupt(interrupt_id);

    }

    return saved_sp;

}

/// Catch-all for unhandled exceptions: print diagnostics and halt.
export fn handle_unhandled(exception_syndrome: u64, faulting_address: u64) noreturn {

    const ec = (exception_syndrome >> 26) & 0x3F;

    // EC 0x20/0x21 = instruction abort; 0x24/0x25 = data abort
    const is_page_fault = (ec == 0x20 or ec == 0x21 or ec == 0x24 or ec == 0x25);

    if (is_page_fault) {

        const fault_addr = asm volatile ("mrs %[out], far_el1"
            : [out] "=r" (-> u64),
        );

        print_exception("Page Fault!", exception_syndrome, fault_addr);

    } else {

        print_exception("Unhandled Exception!", exception_syndrome, faulting_address);

    }

    while (true) {

        asm volatile ("wfe");

    }

}

fn print_exception(label: []const u8, syndrome: u64, address: u64) void {

    uart.print(label);
    uart.print("\r\n\r\n");
    uart.print("syndrome: ");
    uart.print_hex(syndrome);
    uart.print("\r\naddress:  ");
    uart.print_hex(address);
    uart.print("\r\n");

}
