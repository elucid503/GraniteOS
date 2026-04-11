// user/launcher.zig: runs each demo program sequentially via fork + exec + waitpid

const sys = @import("syscall");
const io = @import("io");

const demos = [_][*:0]const u8{ "fork_test", "sched_test", "pipe_test", "signal_test" };

export fn _start() noreturn {

    for (demos) |name| {

        const child_pid = sys.fork();

        if (child_pid == 0) {

            _ = sys.execve(name);

            io.println("exec failed");
            sys.exit(1);

        }

        // Parent waits for the child to finish before launching the next demo.

        _ = sys.waitpid(@intCast(child_pid));

    }

    sys.exit(0);

}
