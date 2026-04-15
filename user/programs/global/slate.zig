// user/slate.zig - SLATE: System Launch And Task Executor

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.println("SLATE ......... Started");

    // Main loop: launch the shell and restart it if it ever exits.

    while (true) {

        const child = sys.fork();

        if (child == 0) {

            _ = sys.execve("/programs/basalt", null);

            io.println("[SLATE] failed to exec basalt");
            sys.exit(1);

        }

        if (child < 0) {

            io.println("[SLATE] fork failed");
            sys.exit(1);

        }

        _ = sys.waitpid(@intCast(child));

        io.println("");
        io.println("[SLATE] shell exited, restarting...");
        io.println("");

    }

}
