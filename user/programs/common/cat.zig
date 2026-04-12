// user/cat.zig - Copies stdin to stdout as a pipe passthrough utility.

const sys = @import("syscall");

export fn _start() noreturn {

    var buf: [512]u8 = undefined;

    while (true) {

        const n = sys.read(sys.STDIN, &buf);

        if (n <= 0) break;

        _ = sys.write(sys.STDOUT, buf[0..@intCast(n)]);

    }

    sys.exit(0);

}
