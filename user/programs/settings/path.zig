// user/programs/settings/path.zig — Manage the binary search path

const sys = @import("syscall");
const io = @import("io");

const PATH_ADD: usize = 0;
const PATH_REMOVE: usize = 1;
const PATH_LIST: usize = 2;

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("usage: path <add|remove> <directory>");
        io.println("       path view");
        sys.exit(1);

    }

    const cmd = str_from_ptr(argv[1] orelse {

        io.println("path: missing command");
        sys.exit(1);

    });

    if (str_eql(cmd, "view")) {

        var buf: [1024]u8 = undefined;
        const n: usize = @bitCast(sys.pathctl(PATH_LIST, @intFromPtr(&buf), buf.len));

        if (n == 0) {

            io.println("(empty)");
            sys.exit(0);

        }

        var pos: usize = 0;

        while (pos < n) {

            var end = pos;

            while (end < n and buf[end] != 0) end += 1;

            if (end > pos) io.println(buf[pos..end]);

            pos = end + 1;

        }

        sys.exit(0);

    }

    if (argc < 3) {

        io.println("path: missing directory argument");
        sys.exit(1);

    }

    const dir = argv[2] orelse {

        io.println("path: missing directory");
        sys.exit(1);

    };

    if (str_eql(cmd, "add")) {

        const result = sys.pathctl(PATH_ADD, @intFromPtr(dir), 0);

        if (result < 0) {

            io.println("path: cannot add (duplicate or full)");
            sys.exit(1);

        }

    } else if (str_eql(cmd, "remove")) {

        const result = sys.pathctl(PATH_REMOVE, @intFromPtr(dir), 0);

        if (result < 0) {

            io.println("path: entry not found");
            sys.exit(1);

        }

    } else {

        io.println("path: unknown command (use add, remove, or view)");
        sys.exit(1);

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
