// user/fs/delete.zig - Delete a file from the virtual file system

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("Usage: delete <filename>");
        sys.exit(1);

    }

    const name = argv[1] orelse {

        io.println("delete: missing filename");
        sys.exit(1);

    };

    const result = sys.delete(name);

    if (result < 0) {

        io.println("delete: failed (file not found or permission denied)");
        sys.exit(1);

    }

    sys.exit(0);

}
