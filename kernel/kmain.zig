// kernel/kmain.zig — Kernel entry point (EL1, MMU off); M1: print over UART and halt

const uart = @import("uart.zig");

export fn kmain() noreturn {

    uart.init();
    uart.print("Hello from GraniteOS!\r\n");

    while (true) {

        asm volatile ("wfe");

    }

}
