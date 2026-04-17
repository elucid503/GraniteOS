// user/sched_test.zig - Demo of preemptive scheduling across forked processes; uses atomic printing

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.atomic_print("Demo ......... Preemptive Scheduling");
    io.atomic_println();
    io.atomic_println();

    var child_pids: [2]usize = undefined;

    // Fork two children
    const child_a = sys.fork();

    if (child_a == 0) {

        run_worker_child("A");

    }

    if (child_a < 0) {

        io.atomic_print("ERROR: fork failed");
        io.atomic_println();
        sys.exit(1);

    }

    child_pids[0] = @intCast(child_a);

    const child_b = sys.fork();

    if (child_b == 0) {

        run_worker_child("B");

    }

    if (child_b < 0) {

        io.atomic_print("ERROR: fork failed");
        io.atomic_println();
        sys.exit(1);

    }

    child_pids[1] = @intCast(child_b);

    // Parent is worker "P"
    run_worker_parent("P");

    // Parent: wait for both children before exiting
    _ = sys.waitpid(child_pids[0]);
    _ = sys.waitpid(child_pids[1]);

    sys.exit(0);

}

fn run_worker_common(name: []const u8) void {

    const pid = sys.getpid();

    var tick: usize = 0;

    while (tick < 3) : (tick += 1) {

        io.atomic_print("[Worker ");
        io.atomic_print(name);
        io.atomic_print(" - PID ");
        io.atomic_print_int(pid);
        io.atomic_print("] tick ");
        io.atomic_print_int(tick);
        io.atomic_println();

        busy_wait(); // burns a scheduling quantum to trigger preemption

    }

    io.atomic_print("[Worker ");
    io.atomic_print(name);
    io.atomic_print(" - PID ");
    io.atomic_print_int(pid);
    io.atomic_print("] done");
    io.atomic_println();

}

fn run_worker_child(name: []const u8) noreturn {

    run_worker_common(name);
    sys.exit(0);

}

fn run_worker_parent(name: []const u8) void {

    run_worker_common(name);

}

fn busy_wait() void {

    var i: usize = 0;

    while (i < 200_000_000) : (i += 1) {

        asm volatile ("nop");

    }

}