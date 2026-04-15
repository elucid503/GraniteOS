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
        var out: [1024]u8 = undefined; // double-worst-case: every byte becomes \r\n
        var out_pos: usize = 0;

        while (true) {

            const n = sys.read(@intCast(fd), &buf);

            if (n <= 0) break;

            // Translate bare \n to \r\n so lines display correctly on a VT100 terminal.

            for (buf[0..@intCast(n)]) |c| {

                if (c == '\n') {

                    out[out_pos] = '\r';
                    out_pos += 1;

                }

                out[out_pos] = c;
                out_pos += 1;

                if (out_pos + 2 > out.len) {

                    _ = sys.write(sys.STDOUT, out[0..out_pos]);
                    out_pos = 0;

                }

            }

        }

        if (out_pos > 0) _ = sys.write(sys.STDOUT, out[0..out_pos]);

        _ = sys.close(@intCast(fd));

    }

    sys.exit(0);

}
