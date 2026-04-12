// user/fs/create.zig - Create an empty file in the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("Usage: create <path>");
        sys.exit(1);

    }

    const name = argv[1] orelse {

        io.println("create: missing filename");
        sys.exit(1);

    };

    const result = sys.create(name);

    if (result < 0) {

        io.println("create: failed (file may already exist or filesystem full)");
        sys.exit(1);

    }

    sys.exit(0);

}
