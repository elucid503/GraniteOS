// user/launcher.zig: runs each demo program sequentially via fork + exec + waitpid

const sys = @import("lib/syscall.zig");
const io = @import("lib/io.zig");

const demos = [_][*:0]const u8{ "fork_test", "sched_test" };

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
