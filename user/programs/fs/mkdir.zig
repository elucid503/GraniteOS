// user/fs/mkdir.zig - Create a directory in the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("Usage: mkdir <path>");
        sys.exit(1);

    }

    const path = argv[1] orelse {

        io.println("mkdir: missing path");
        sys.exit(1);

    };

    const result = sys.mkdir(path);

    if (result < 0) {

        io.println("mkdir: failed (exists, invalid path, or filesystem full)");
        sys.exit(1);

    }

    sys.exit(0);

}
