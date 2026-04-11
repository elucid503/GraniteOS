// user/signal_test.zig: demo of signal delivery, handling, and default terminate

const sys = @import("syscall");
const io = @import("io");

var signal_received: usize = 0;

// Signal handler for 'interrupt' (signal 1).
// Must call sigreturn() to resume normal execution.
fn handle_interrupt(_: usize) callconv(.c) noreturn {

    signal_received = 1;
    sys.sigreturn();

}

export fn _start() noreturn {

    io.println("Demo ......... Signals\r\n");

    const pid = sys.getpid();

    // 1. Register a handler for 'interrupt' and send it to ourselves.
    //    The handler sets a flag and calls sigreturn, resuming right after kill().

    _ = sys.sigaction(1, @intFromPtr(&handle_interrupt));

    io.print("[PID ");
    io.print_int(pid);
    io.println("] sending 'interrupt' to self...");

    _ = sys.kill(pid, 1);

    // Execution continues here after sigreturn.

    io.print("[PID ");
    io.print_int(pid);

    if (signal_received != 0) {

        io.println("] handler ran and returned successfully!");

    } else {

        io.println("] ERROR: signal not received");

    }

    // 2. Fork a child and terminate it with the default 'terminate' signal.

    const child = sys.fork();

    if (child < 0) {

        io.println("[signal] fork() failed");
        sys.exit(1);

    }

    if (child == 0) {

        io.print("[Child PID ");
        io.print_int(sys.getpid());
        io.println("] running... (will be terminated)");

        // Busy-loop until terminated by the parent's signal.
        while (true) asm volatile ("nop");

    }

    // Give the child time to print before killing it.

    var i: usize = 0;
    while (i < 50_000_000) : (i += 1) asm volatile ("nop");

    _ = sys.kill(@intCast(child), 0); // signal 0 = terminate
    _ = sys.waitpid(@intCast(child));

    io.println("[Parent] child was terminated by signal\r\n");

    sys.exit(0);

}
