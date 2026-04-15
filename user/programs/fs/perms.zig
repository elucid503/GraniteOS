// user/programs/fs/perms.zig — Set file permissions (read, write, exec, delete)

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("usage: perms <file> [-read|-write|-exec|-delete true|false] [-all true|false]");
        sys.exit(1);

    }

    const file_name = argv[1] orelse {

        io.println("perms: missing filename");
        sys.exit(1);

    };

    // Defaults: read-only (matches user-created file defaults)
    var can_read: bool = true;
    var can_write: bool = false;
    var can_exec: bool = false;
    var can_delete: bool = false;
    var had_flags: bool = false;

    var i: usize = 2;

    while (i < argc) : (i += 1) {

        const flag = str_from_ptr(argv[i] orelse continue);

        if (i + 1 >= argc) {

            io.println("perms: missing value after flag");
            sys.exit(1);

        }

        const val_str = str_from_ptr(argv[i + 1] orelse {

            io.println("perms: missing value after flag");
            sys.exit(1);

        });

        const val = parse_bool(val_str);

        if (val == null) {

            io.println("perms: expected true or false");
            sys.exit(1);

        }

        if (str_eql(flag, "-all")) {

            can_read = val.?;
            can_write = val.?;
            can_exec = val.?;
            can_delete = val.?;
            had_flags = true;

        } else if (str_eql(flag, "-read")) {

            can_read = val.?;
            had_flags = true;

        } else if (str_eql(flag, "-write")) {

            can_write = val.?;
            had_flags = true;

        } else if (str_eql(flag, "-exec")) {

            can_exec = val.?;
            had_flags = true;

        } else if (str_eql(flag, "-delete")) {

            can_delete = val.?;
            had_flags = true;

        } else {

            io.print("perms: unknown flag: ");
            io.println(flag);
            sys.exit(1);

        }

        i += 1;

    }

    if (!had_flags) {

        io.println("perms: no permission flags specified");
        sys.exit(1);

    }

    const mask: usize = (if (can_read) @as(usize, 1) else 0) |
        (if (can_write) @as(usize, 2) else 0) |
        (if (can_exec) @as(usize, 4) else 0) |
        (if (can_delete) @as(usize, 8) else 0);

    const result = sys.chmod(file_name, mask);

    if (result < 0) {

        io.println("perms: cannot set permissions (file not found?)");
        sys.exit(1);

    }

    sys.exit(0);

}

fn str_from_ptr(ptr: [*:0]const u8) []const u8 {

    var len: usize = 0;
    while (ptr[len] != 0) len += 1;
    return ptr[0..len];

}

fn parse_bool(s: []const u8) ?bool {

    if (str_eql(s, "true")) return true;
    if (str_eql(s, "false")) return false;
    return null;

}

fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
