// user/common/status.zig - Display system status (scheduler or memory)

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("Usage: status <scheduler | memory | disk>");
        sys.exit(1);

    }

    const subsystem = argv[1] orelse {

        io.println("status: missing argument");
        sys.exit(1);

    };

    var info_type: usize = undefined;

    if (str_eql_z(subsystem, "scheduler")) {

        info_type = 0;

    } else if (str_eql_z(subsystem, "memory")) {

        info_type = 1;

    } else if (str_eql_z(subsystem, "disk")) {

        info_type = 2;

    } else {

        io.println("status: unknown subsystem (use 'scheduler', 'memory', or 'disk')");
        sys.exit(1);

    }

    var buf: [1024]u8 = undefined;
    const n = sys.sysinfo(info_type, &buf);

    if (n > 0) {

        io.print("\r\n");
        io.print(buf[0..n]);
        io.print("\r\n");

    }

    sys.exit(0);

}

fn str_eql_z(a: [*:0]const u8, b: []const u8) bool {

    var i: usize = 0;

    while (i < b.len) : (i += 1) {

        if (a[i] == 0 or a[i] != b[i]) return false;

    }

    return a[i] == 0;

}
