// user/view.zig - Display file contents

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("usage: view <filename>");
        sys.exit(1);

    }

    if (argv[1]) |file_name| {

        const fd = sys.open(file_name, sys.OPEN_READ);

        if (fd < 0) {

            io.println("error: cannot open file");
            sys.exit(1);

        }

        var buf: [512]u8 = undefined;

        while (true) {

            const n = sys.read(@intCast(fd), &buf);

            if (n <= 0) break;

            _ = sys.write(sys.STDOUT, buf[0..@intCast(n)]);

        }

        _ = sys.close(@intCast(fd));

    }

    sys.exit(0);

}
