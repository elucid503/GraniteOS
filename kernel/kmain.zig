// kernel/kmain.zig — Kernel entry point (EL1, MMU on via identity map)

const uart = @import("drivers/uart.zig");
const gic = @import("drivers/gic.zig");

const timer = @import("scheduler/timer.zig");
const scheduler = @import("scheduler/scheduler.zig");

const exceptions = @import("exceptions/exceptions.zig");

const physical_allocator = @import("memory/physical_allocator.zig");
const heap = @import("memory/heap.zig");

export fn kmain() noreturn {

    uart.init(); // Initialize UART

    uart.print("Welcome to GraniteOS!\r\n");

    uart.print("\r\n");

    uart.print("MMU ......... Enabled (identity map)\r\n");

    physical_allocator.init(); // Initialize physical page allocator

    uart.print("Physical Memory ......... Initialized\r\n");

    heap.init(16); // Initialize kernel heap with 16 pages (64KB)

    uart.print("Kernel Heap ......... Initialized\r\n");

    gic.init(); // Initialize GIC

    uart.print("GIC ......... Initialized\r\n");

    timer.init(); // Initialize timer

    uart.print("Timer ......... Set to 100ms\r\n");

    scheduler.init(); // Initialize internal scheduler

    uart.print("Internal Scheduler ......... ");

    uart.putchar('0' + @as(u8, @intCast(scheduler.task_count)));
    uart.print(" Task(s)\r\n");

    uart.print("\r\n");

    exceptions.enable_interrupts(); // Enable interrupts globally

    // Idle loop — the scheduler preempts this to run other tasks

    while (true) {

        asm volatile ("wfe");

    }

}
