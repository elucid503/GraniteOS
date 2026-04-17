// user/clear.zig - Clears the terminal screen using ANSI escape codes

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.print("\x1b[2J\x1b[H"); // clear screen and move cursor to top-left

    sys.exit(0);

}
