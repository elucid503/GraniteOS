// user/location/path.zig - Print the shell's current working directory (absolute path)

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);

    if (n < 0) {

        io.println("path: cannot read current directory");
        sys.exit(1);

    }

    const len: usize = @intCast(n);

    if (len <= 1) {

        io.println("/");

    } else {

        io.println(buf[0 .. len - 1]);

    }

    sys.exit(0);

}
