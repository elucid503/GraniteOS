// user/sched_test.zig: demo of preemptive scheduling across forked processes

const sys = @import("lib/syscall.zig");
const io = @import("lib/io.zig");

export fn _start() noreturn {

    io.println("Demo ......... Preemptive Scheduling\r\n");

    // Fork two children so three processes (parent + 2 children) run concurrently.
    // Each prints a numbered message, proving the scheduler round-robins between them.

    const child_a = sys.fork();

    if (child_a == 0) {

        run_worker("A");

    }

    const child_b = sys.fork();

    if (child_b == 0) {

        run_worker("B");

    }

    // Parent is worker "P"
    run_worker("P");

}

fn run_worker(name: []const u8) noreturn {

    const pid = sys.getpid();

    var tick: usize = 0;

    while (tick < 3) : (tick += 1) {

        io.print("[Worker ");
        io.print(name);
        io.print(" - PID ");
        io.print_int(pid);
        io.print("] tick ");
        io.print_int(tick);
        io.println("");

        // the busy-wait is to burn through a scheduling quantum so the timer
        // preempts us and switches to another worker.

        busy_wait();

    }

    io.print("[Worker ");
    io.print(name);
    io.print(" - PID ");
    io.print_int(pid);
    io.println("] done");

    sys.exit(0);

}

fn busy_wait() void {

    var i: usize = 0;

    while (i < 200_000_000) : (i += 1) {

        asm volatile ("nop");

    }

}
