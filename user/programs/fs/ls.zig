// user/fs/ls.zig - List files in the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    var buf: [2048]u8 = undefined;

    const dir_arg: ?[*:0]const u8 = if (argc >= 2) argv[1] else null;

    const total = if (dir_arg) |d|

        sys.listfiles_in(&buf, d)

    else

        sys.listfiles(&buf);

    if (total == 0) {

        io.println("(no files)");
        sys.exit(0);

    }

    // Entries are name\0kind\0size\0 (kind is 'f' or 'd').

    var pos: usize = 0;
    var count: usize = 0;

    while (pos < total) {

        const name_start = pos;

        while (pos < total and buf[pos] != 0) pos += 1;

        const name = buf[name_start..pos];
        pos += 1;

        if (pos >= total) break;

        const kind = buf[pos];
        pos += 1;

        if (pos >= total or buf[pos] != 0) break;

        pos += 1;

        const size_start = pos;

        while (pos < total and buf[pos] != 0) pos += 1;

        const size_str = buf[size_start..pos];
        pos += 1;

        if (name.len == 0) continue;

        io.print("  ");
        io.print(name);

        var padding: usize = 0;

        while (padding + name.len < 20) : (padding += 1) {
            io.print(" ");
        }

        io.print("  ");

        if (kind == 'd') {

            io.println("<dir>");

        } else {

            io.print(size_str);
            io.println(" bytes");

        }

        count += 1;

    }

    if (count == 0) {

        io.println("(no files)");

    }

    sys.exit(0);

}
