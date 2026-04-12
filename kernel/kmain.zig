// kernel/kmain.zig - Kernel entry point (EL1, MMU on via identity map)

const std = @import("std");

const uart = @import("drivers/uart.zig");
const gic = @import("drivers/gic.zig");

const timer = @import("scheduler/timer.zig");
const scheduler = @import("scheduler/scheduler.zig");

const exceptions = @import("exceptions/exceptions.zig");

const physical_allocator = @import("memory/physical_allocator.zig");
const heap = @import("memory/heap.zig");

const process = @import("process/process.zig");
const fs = @import("fs/fs.zig");

const user_programs = @import("user_programs"); // generated at compile time by build.zig

export fn kmain() noreturn {

    uart.init();

    uart.print("Welcome to GraniteOS!\r\n\r\n");

    uart.print("MMU ......... Enabled (identity map)\r\n");

    physical_allocator.init();
    uart.print("Physical Memory ......... Initialized\r\n");

    heap.init(16);
    uart.print("Kernel Heap ......... Initialized\r\n");

    fs.init();
    uart.print("File System ......... Initialized\r\n");

    gic.init();
    uart.print("GIC ......... Initialized\r\n");

    timer.init();
    uart.print("Timer ......... Set to 100ms\r\n");

    scheduler.init();

    // Time to spawn SLATE (System Launch And Task Executor) as the first user process.

    for (user_programs.programs) |prog| {

        if (std.mem.eql(u8, prog.name, "slate")) {

            process.spawn_elf(prog.elf);
            break;

        }

    }

    uart.print("User Programs ......... Loaded\r\n");

    exceptions.enable_interrupts();

    while (true) asm volatile ("wfe");

}
