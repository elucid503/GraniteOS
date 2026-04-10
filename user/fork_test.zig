// user/fork_test.zig: demo of fork() + memory isolation + execve()

const sys = @import("lib/syscall.zig");
const io = @import("lib/io.zig");

export fn _start() noreturn {

    const my_pid = sys.getpid();

    io.println("Demo ......... Fork, Exec & Memory Isolation\r\n");

    // Heap allocation demo: grows the break by one page and stamp a
    // sentinel value that encodes the current PID so we can verify
    // each process sees and modifies its own independent copy.

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

    // fork(): duplicates the address space.  The child gets an
    // independent physical copy of every mapped page - including the
    // heap page we just wrote.  Returns 0 in the child, child-PID in
    // the parent, negative on error.

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

        // Overwrite the child's physical copy. The parent's page is
        // a separate physical page so the parent will NOT see this.

        magic.* = 0xCAFE_BABE_0000_0000 | @as(u64, cpid);

        io.print("[Child - PID ");
        io.print_int(cpid);
        io.print("] overwrote magic to 0x");
        io.print_hex(magic.*);
        io.println(" (isolated from parent's view)");

        // exec: replace this child's image with 'hello'
        // execve frees the current address space, loads the named ELF,
        // and returns to EL0 at the new entry point. The PID is kept.

        io.print("[Child - PID ");
        io.print_int(cpid);
        io.println("] now exec'ing 'hello'...");
        io.print("\r\n");

        _ = sys.execve("hello"); // only returns on error

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

        // The parent's heap page was not touched by the child: its
        // physical page is separate after the copy-on-write fork.

        io.print("[Parent - PID ");
        io.print_int(my_pid);
        io.print("] magic is 0x");
        io.print_hex(magic.*); // must still be 0xdeadbeef...
        io.println(" (isolated from child's write)");
        io.println("");

        sys.exit(0);

    }

}
