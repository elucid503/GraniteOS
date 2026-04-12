// user/own.zig - Set file permissions. For now force-sets the owner to the current user.

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("usage: own <filename>");
        sys.exit(1);

    }

    if (argv[1]) |file_name| {

        const result = sys.chmod(file_name, true, true);

        if (result < 0) {

            io.println("error: cannot set permissions");
            sys.exit(1);

        }

    }

    sys.exit(0);

}
