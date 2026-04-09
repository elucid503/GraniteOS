// user/fork_test.zig - Demonstrates fork(), exec(), and per-process memory isolation.
//
// Expected output (order may interleave at timer boundaries):
//   PID 1: heap at 0x<addr>, wrote magic 0xdeadbeef00000001
//   [parent 1] forked child PID=2
//   [parent 1] magic=0xdeadbeef00000001  <- unchanged; child's write stays isolated
//   [child  2] inherited magic=0xdeadbeef00000001  <- copy of parent's value
//   [child  2] overwrote to 0xcafebabe00000002  <- child's own copy
//   [child  2] exec'ing 'hello'...
//   Hello from GraniteOS user space!    <- hello runs as the exec'd child (same PID)
//   PID: 2
//   brk: OK

const sys = @import("lib/syscall.zig");
const io  = @import("lib/io.zig");

export fn _start() noreturn {

    const my_pid = sys.getpid();

    io.println("\r\n=== fork + memory isolation + exec ===");

    // ----------------------------------------------------------------
    // Heap allocation demo: grow the break by one page and stamp a
    // sentinel value that encodes the current PID so we can verify
    // each process sees and modifies its own independent copy.
    // ----------------------------------------------------------------

    const heap: usize = sys.brk(0);           // query current break
    _ = sys.brk(heap + 4096);                 // allocate one page

    const magic: *u64 = @ptrFromInt(heap);    // first word of that page
    magic.* = 0xDEAD_BEEF_0000_0000 | @as(u64, my_pid);

    io.print("PID ");
    io.print_int(my_pid);
    io.print(": heap at 0x");
    io.print_hex(heap);
    io.print(", wrote magic 0x");
    io.print_hex(magic.*);
    io.println("");

    // ----------------------------------------------------------------
    // fork(): duplicates the address space.  The child gets an
    // independent physical copy of every mapped page — including the
    // heap page we just wrote.  Returns 0 in the child, child-PID in
    // the parent, negative on error.
    // ----------------------------------------------------------------

    const ret = sys.fork();

    if (ret < 0) {
        io.println("fork() failed");
        sys.exit(1);
    }

    if (ret == 0) {

        // ---- CHILD ------------------------------------------------
        const cpid = sys.getpid();

        io.print("[child  ");
        io.print_int(cpid);
        io.print("] inherited magic=0x");
        io.print_hex(magic.*);        // must match parent's pre-fork value
        io.println("");

        // Overwrite the child's physical copy.  The parent's page is
        // a separate physical page so the parent will NOT see this.
        magic.* = 0xCAFE_BABE_0000_0000 | @as(u64, cpid);

        io.print("[child  ");
        io.print_int(cpid);
        io.print("] overwrote to  0x");
        io.print_hex(magic.*);
        io.println("  (child-private copy)");

        // ---- exec: replace this child's image with 'hello' ---------
        // execve frees the current address space, loads the named ELF,
        // and returns to EL0 at the new entry point.  The PID is kept.
        io.print("[child  ");
        io.print_int(cpid);
        io.println("] exec'ing 'hello'...");

        _ = sys.execve("hello");       // only returns on error
        io.println("[child] execve failed!");
        sys.exit(1);

    } else {

        // ---- PARENT -----------------------------------------------
        const child_pid: usize = @intCast(ret);

        io.print("[parent ");
        io.print_int(my_pid);
        io.print("] forked child PID=");
        io.print_int(child_pid);
        io.println("");

        // The parent's heap page was not touched by the child: its
        // physical page is separate after the copy-on-write fork.
        io.print("[parent ");
        io.print_int(my_pid);
        io.print("] magic=0x");
        io.print_hex(magic.*);        // must still be 0xdeadbeef...
        io.println("  (isolated from child's write)");

        sys.exit(0);

    }

}
