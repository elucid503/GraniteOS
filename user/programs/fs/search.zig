// user/programs/fs/search.zig — Search files by name or content

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 3) {

        io.println("usage: search -name <query> | -content <query>");
        sys.exit(1);

    }

    const flag = str_from_ptr(argv[1] orelse {

        io.println("search: missing flag");
        sys.exit(1);

    });

    const query = argv[2] orelse {

        io.println("search: missing query");
        sys.exit(1);

    };

    var mode: usize = 0;

    if (str_eql(flag, "-name")) {

        mode = 0;

    } else if (str_eql(flag, "-content")) {

        mode = 1;

    } else {

        io.println("search: use -name or -content");
        sys.exit(1);

    }

    var buf: [2048]u8 = undefined;
    const n = sys.search(&buf, query, mode);

    if (n == 0) {

        io.println("(no results)");
        sys.exit(0);

    }

    // Parse null-separated paths and print each on its own line
    var pos: usize = 0;

    while (pos < n) {

        var end = pos;

        while (end < n and buf[end] != 0) end += 1;

        if (end > pos) io.println(buf[pos..end]);

        pos = end + 1;

    }

    sys.exit(0);

}

fn str_from_ptr(ptr: [*:0]const u8) []const u8 {

    var len: usize = 0;
    while (ptr[len] != 0) len += 1;
    return ptr[0..len];

}

fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
