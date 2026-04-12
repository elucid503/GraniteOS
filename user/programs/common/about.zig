// user/common/about.zig - About GraniteOS

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.println("");
    io.println("GraniteOS");
    io.println("A minimal ARM64 operating system built from scratch in Zig.\r\n");

    io.println("Features:");
    io.println("  - Preemptive round-robin scheduler");
    io.println("  - Per-process virtual memory with 4-level page tables");
    io.println("  - ELF binary loading and fork/exec process model");
    io.println("  - Pipe-based IPC with shell pipeline support");
    io.println("  - Signal delivery and handling");
    io.println("  - In-memory virtual file system");
    io.println("  - BASALT interactive shell");
    io.println("  - SLATE init system\r\n");

    io.println("Type 'help' to see available commands.");
    io.println("");

    sys.exit(0);

}
