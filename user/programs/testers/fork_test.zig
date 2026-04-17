// user/fork_test.zig: demo of fork() + memory isolation + execve()

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    const my_pid = sys.getpid();

    io.println("Demo ......... Fork, Exec & Memory Isolation\r\n");

    // Allocates one heap page and stamps a PID-encoded magic value to verify copy-on-write isolation.

    const heap: usize = sys.brk(0); // query current break
    _ = sys.brk(heap + 4096); // allocate one page

    const magic: *u64 = @ptrFromInt(heap); // first word of that page
    magic.* = 0xDEAD_BEEF_0000_0000 | @as(u64, my_pid);

    io.print("[Parent - PID ");
    io.print_int(my_pid);
    io.print("] heap at 0x");
    io.print_hex(heap);
    io.print(", wrote magic 0x");
    io.print_hex(magic.*);
    io.println("");

    const ret = sys.fork();

    if (ret < 0) {

        io.println("fork() failed");
        sys.exit(1);

    }

    if (ret == 0) {

        // CHILD

        const cpid = sys.getpid();

        io.print("[Child - PID ");
        io.print_int(cpid);
        io.println("] started");

        // Overwrites the child's copy; parent's physical page is separate.

        magic.* = 0xCAFE_BABE_0000_0000 | @as(u64, cpid);

        io.print("[Child - PID ");
        io.print_int(cpid);
        io.print("] overwrote magic to 0x");
        io.print_hex(magic.*);
        io.println(" (isolated from parent's view)");

        // Replaces this child's image with 'hello'; PID is preserved.

        io.print("[Child - PID ");
        io.print_int(cpid);
        io.println("] now exec'ing 'hello'...");
        io.print("\r\n");

        _ = sys.execve("hello", null); // only returns on error

        io.println("[child] execve failed!");
        sys.exit(1);

    } else {

        // PARENT

        const child_pid: usize = @intCast(ret);

        io.print("[Parent - PID ");
        io.print_int(my_pid);
        io.print("] forked child, PID ");
        io.print_int(child_pid);
        io.println("");

        // Parent's page is unmodified; each process has its own physical copy.

        io.print("[Parent - PID ");
        io.print_int(my_pid);
        io.print("] magic is 0x");
        io.print_hex(magic.*); // must still be 0xdeadbeef...
        io.println(" (isolated from child's write)");
        io.println("");

        sys.exit(0);

    }

}
