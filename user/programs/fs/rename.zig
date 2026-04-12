// user/fs/rename.zig - Rename a file in the virtual file system.

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 3) {

        io.println("Usage: rename <old_name> <new_name>");
        sys.exit(1);

    }

    const old_name = argv[1] orelse {

        io.println("rename: missing old name");
        sys.exit(1);

    };

    const new_name = argv[2] orelse {

        io.println("rename: missing new name");
        sys.exit(1);

    };

    const result = sys.rename(old_name, new_name);

    if (result < 0) {

        io.println("rename: failed (not found, name taken, or permission denied)");
        sys.exit(1);

    }

    sys.exit(0);

}
