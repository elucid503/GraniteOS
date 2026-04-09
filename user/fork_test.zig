// user/fork_test.zig - Minimal test to verify EL0 execution with per-process tables.

const sys = @import("lib/syscall.zig");

export fn _start() noreturn {
    // Direct write syscall — no library calls, no stack frame setup beyond this fn.
    const msg = "A";
    _ = sys.write(1, msg);
    sys.exit(0);
}
