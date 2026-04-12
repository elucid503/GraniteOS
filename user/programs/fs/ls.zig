// user/fs/ls.zig - List files in the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    var buf: [2048]u8 = undefined;
    const total = sys.listfiles(&buf);

    if (total == 0) {

        io.println("(no files)");
        sys.exit(0);

    }

    // Entries are name\0size_string\0 pairs.

    var pos: usize = 0;
    var count: usize = 0;

    while (pos < total) {

        // Read name.
        const name_start = pos;

        while (pos < total and buf[pos] != 0) pos += 1;

        const name = buf[name_start..pos];
        pos += 1;

        // Read size string.
        const size_start = pos;

        while (pos < total and buf[pos] != 0) pos += 1;

        const size_str = buf[size_start..pos];
        pos += 1;

        if (name.len == 0) continue;

        io.print("  ");
        io.print(name);

        // Pad name to 20 chars.
        var padding: usize = 0;

        while (padding + name.len < 20) : (padding += 1) {
            io.print(" ");
        }

        io.print("  ");
        io.print(size_str);
        io.println(" bytes");

        count += 1;

    }

    if (count == 0) {

        io.println("(no files)");

    }

    sys.exit(0);

}
