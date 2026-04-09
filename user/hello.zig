// user/hello.zig - Hello world user process; demonstrates write, getpid, brk, exit.

const sys = @import("lib/syscall.zig");
const io  = @import("lib/io.zig");

export fn _start() noreturn {

    io.println("Hello from GraniteOS user space!");

    // Show this process's PID.
    io.print("PID: ");
    io.print_int(sys.getpid());
    io.println("");

    // Verify brk: allocate one page of heap and confirm the break advanced.
    const heap_start = sys.brk(0);
    const heap_end   = sys.brk(heap_start + 4096);

    if (heap_end == heap_start + 4096) {
        io.println("brk: OK");
    } else {
        io.println("brk: failed");
    }

    sys.exit(0);

}
