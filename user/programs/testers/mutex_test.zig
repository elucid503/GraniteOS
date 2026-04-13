// user/mutex_test.zig: Mutex verification test

const sys = @import("syscall");
const io = @import("io");

const Mutex = struct {

    state: u32 = 0,

    pub fn lock(self: *Mutex) void {

        while (true) {

            if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;
            asm volatile ("wfe");

        }

    }

    pub fn unlock(self: *Mutex) void {

        @atomicStore(u32, &self.state, 0, .release);
        asm volatile ("sev");

    }

};

export fn _start() noreturn {

    io.atomic_print("Demo ......... Mutex Verification");
    io.atomic_println();
    io.atomic_println();

    const child_a = sys.fork();

    if (child_a == 0) {

        run_worker_child("A");

    }

    if (child_a < 0) {

        io.atomic_print("ERROR: fork failed");
        io.atomic_println();
        sys.exit(1);

    }

    const child_b = sys.fork();

    if (child_b == 0) {

        run_worker_child("B");

    }

    if (child_b < 0) {

        io.atomic_print("ERROR: fork failed");
        io.atomic_println();
        sys.exit(1);

    }

    run_worker_parent("P");

    _ = sys.waitpid(@intCast(child_a));
    _ = sys.waitpid(@intCast(child_b));

    io.atomic_println();
    io.atomic_print("All workers completed successfully.");
    io.atomic_println();

    sys.exit(0);

}

fn run_worker_common(name: []const u8) void {

    const pid = sys.getpid();

    io.atomic_print("[");
    io.atomic_print(name);
    io.atomic_print("/");
    io.atomic_print_int(pid);
    io.atomic_print("] START");
    io.atomic_println();

    var round: usize = 0;

    while (round < 3) : (round += 1) {

        var test_lock: Mutex = .{};

        if (test_lock.state != 0) {

            io.atomic_print("ERROR: mutex not unlocked initially");
            io.atomic_println();
            sys.exit(1);

        }

        test_lock.lock();

        if (test_lock.state != 1) {

            io.atomic_print("ERROR: mutex not locked after lock()");
            io.atomic_println();
            sys.exit(1);

        }

        io.atomic_print("[");
        io.atomic_print(name);
        io.atomic_print("/");
        io.atomic_print_int(pid);
        io.atomic_print("] Round ");
        io.atomic_print_int(round);
        io.atomic_print(" locked");
        io.atomic_println();

        busy_wait();

        test_lock.unlock();

        if (test_lock.state != 0) {

            io.atomic_print("ERROR: mutex not unlocked after unlock()");
            io.atomic_println();
            sys.exit(1);

        }

        io.atomic_print("[");
        io.atomic_print(name);
        io.atomic_print("/");
        io.atomic_print_int(pid);
        io.atomic_print("] Round ");
        io.atomic_print_int(round);
        io.atomic_print(" released");
        io.atomic_println();

    }

    io.atomic_print("[");
    io.atomic_print(name);
    io.atomic_print("/");
    io.atomic_print_int(pid);
    io.atomic_print("] PASS");
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
