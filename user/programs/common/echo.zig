// user/echo.zig - Prints arguments to stdout, separated by spaces

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    var i: usize = 1;

    while (i < argc) : (i += 1) {

        if (i > 1) io.print(" ");

        if (argv[i]) |arg| {

            var len: usize = 0;

            while (arg[len] != 0) len += 1;

            io.print(arg[0..len]);

        }

    }

    io.println("");

    sys.exit(0);

}
