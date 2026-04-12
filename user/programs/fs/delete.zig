// user/fs/delete.zig - Delete a file or an empty directory in the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("Usage: delete <path> OR delete -dir <directory>");
        sys.exit(1);

    }

    if (argc == 2) {

        const only = argv[1] orelse {

            io.println("delete: missing path");
            sys.exit(1);

        };

        if (str_eql(only, "-dir")) {

            io.println("Usage: delete -dir <directory>");
            sys.exit(1);

        }

    } else if (argc >= 3) {

        const flag = argv[1] orelse {

            io.println("delete: missing flag");
            sys.exit(1);

        };

        if (str_eql(flag, "-dir")) {

            const dir = argv[2] orelse {

                io.println("delete: missing directory name");
                sys.exit(1);

            };

            const r = sys.rmdir(dir);

            if (r < 0) {

                io.println("delete: cannot remove directory (cwd inside tree, permission denied, or not a directory)");
                sys.exit(1);

            }

            sys.exit(0);

        }

    }

    const path = argv[1] orelse {

        io.println("delete: missing path");
        sys.exit(1);

    };

    const r = sys.delete(path);

    if (r < 0) {

        io.println("delete: cannot remove file (not found, is a directory, or permission denied)");
        sys.exit(1);

    }

    sys.exit(0);

}

fn str_eql(a: [*:0]const u8, b: []const u8) bool {

    var i: usize = 0;

    while (true) : (i += 1) {

        const ac = a[i];
        const bc = if (i < b.len) b[i] else 0;

        if (ac == 0) return bc == 0;
        if (ac != bc) return false;

    }

}
