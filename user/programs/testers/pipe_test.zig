// user/pipe_test.zig: demo of pipe-based inter-process communication

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.println("\r\nDemo ......... Pipes\r\n");

    var fds: [2]usize = undefined;
    const pipe_result = sys.pipe(&fds);

    if (pipe_result < 0) {

        io.println("[Pipe] pipe() failed");
        sys.exit(1);

    }

    io.print("[Pipe] created: read fd is ");
    io.print_int(fds[0]);
    io.print(", write fd is ");
    io.print_int(fds[1]);
    io.println("");

    const child = sys.fork();

    if (child < 0) {

        io.println("[Pipe] fork() failed");
        sys.exit(1);

    }

    if (child == 0) {

        // Child: close write end, read from pipe

        _ = sys.close(fds[1]);

        var buf: [64]u8 = undefined;
        const n = sys.read(fds[0], &buf);

        io.print("[Child] read ");
        io.print_int(@intCast(n));
        io.print(" bytes: ");

        if (n > 0) io.print(buf[0..@intCast(n)]);

        io.println("");

        _ = sys.close(fds[0]);
        sys.exit(0);

    }

    // Parent: close read end, write message through pipe

    _ = sys.close(fds[0]);

    const msg = "Hello through the pipe!";
    const written = sys.write(fds[1], msg);

    io.print("[Parent] wrote ");
    io.print_int(@intCast(written));
    io.println(" bytes to pipe");

    _ = sys.close(fds[1]);

    _ = sys.waitpid(@intCast(child));
    io.println("[Parent] child has exited\r\n");

    sys.exit(0);

}
