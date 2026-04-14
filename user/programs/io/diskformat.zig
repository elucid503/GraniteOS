// user/io/diskformat.zig - Wipe the persistent disk and reset the file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    _ = argc;
    _ = argv;

    io.println("WARNING: This will erase all files and persistent disk data.");
    io.print("Type 'yes' to confirm: ");

    var buf: [8]u8 = undefined;
    const input = io.read_line(&buf);

    if (!str_eql(input, "yes")) {

        io.println("Aborted.");
        sys.exit(1);

    }

    _ = sys.diskformat();

    io.println("Disk formatted. File system restored to defaults.");
    sys.exit(0);

}

fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
