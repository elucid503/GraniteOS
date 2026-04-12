// user/wc.zig - Count lines and bytes from stdin

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    var buf: [512]u8 = undefined;

    var lines: usize = 0;
    var bytes: usize = 0;

    while (true) {

        const n = sys.read(sys.STDIN, &buf);

        if (n <= 0) break;

        const count: usize = @intCast(n);
        bytes += count;

        for (buf[0..count]) |c| {

            if (c == '\n') lines += 1;

        }

    }

    io.print("  ");
    io.print_int(lines);
    io.print(" lines, ");
    io.print_int(bytes);
    io.println(" bytes");

    sys.exit(0);

}
