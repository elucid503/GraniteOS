// user/smp_test.zig: demo of true SMP parallelism across multiple cores

const sys = @import("syscall");
const io = @import("io");

const WORKERS: usize = 4;
const ITERS: usize = 150_000_000;

export fn _start() noreturn {

    io.println("Demo ......... SMP Parallelism\r\n");
    io.print("Spawning ");
    io.print_int(WORKERS);
    io.println(" workers...\r\n");

    var pids: [WORKERS]usize = undefined;

    for (0..WORKERS) |i| {

        const ret = sys.fork();

        if (ret < 0) {

            io.println("fork failed");
            sys.exit(1);

        }

        if (ret == 0) {
            run_worker(i);
        }

        pids[i] = @intCast(ret);

    }

    // Parent: wait for all children.

    for (0..WORKERS) |i| {
        _ = sys.waitpid(pids[i]);
    }

    io.println("\r\nAll workers finished.");
    io.println("Garbled output never looked so good.");
    sys.exit(0);

}

fn run_worker(id: usize) noreturn {

    io.print("[core-test ");
    io.print_int(id);
    io.print(" PID ");
    io.print_int(sys.getpid());
    io.println("] start");

    // Burn CPU so the scheduler can't finish us in one tick

    var i: usize = 0;

    while (i < ITERS) : (i += 1) {
        asm volatile ("nop");
    }

    io.print("[core-test ");
    io.print_int(id);
    io.print(" PID ");
    io.print_int(sys.getpid());
    io.println("] done");

    sys.exit(0);

}
