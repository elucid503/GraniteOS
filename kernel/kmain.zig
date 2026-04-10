// kernel/kmain.zig - Kernel entry point (EL1, MMU on via identity map)

const uart = @import("drivers/uart.zig");
const gic = @import("drivers/gic.zig");

const timer = @import("scheduler/timer.zig");
const scheduler = @import("scheduler/scheduler.zig");

const exceptions = @import("exceptions/exceptions.zig");

const physical_allocator = @import("memory/physical_allocator.zig");
const heap = @import("memory/heap.zig");

const process = @import("process/process.zig");

// Auto-generated module: all *.zig files in user/ compiled to ELF and embedded.
const user_programs = @import("user_programs");

export fn kmain() noreturn {

    uart.init();

    uart.print("Welcome to GraniteOS!\r\n\r\n");

    uart.print("MMU ......... Enabled (identity map)\r\n");

    physical_allocator.init();
    uart.print("Physical Memory ......... Initialized\r\n");

    heap.init(16);
    uart.print("Kernel Heap ......... Initialized\r\n");

    gic.init();
    uart.print("GIC ......... Initialized\r\n");

    timer.init();
    uart.print("Timer ......... Set to 100ms\r\n");

    scheduler.init();

    // Spawn every embedded user binary as an EL0 process.
    for (user_programs.programs) |prog| {

        process.spawn_elf(prog.elf);

    }

    uart.print("User Processes ......... ");
    uart.putchar('0' + @as(u8, @intCast(user_programs.programs.len)));
    uart.print(" loaded (");

    for (user_programs.programs, 0..) |prog, i| {

        uart.print(prog.name);
        if (i + 1 < user_programs.programs.len) uart.print(", ");

    }

    uart.print(")\r\n\r\n");

    exceptions.enable_interrupts();

    while (true) asm volatile ("wfe");

}
