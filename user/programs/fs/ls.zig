// user/fs/ls.zig - List files in the virtual file system
//
// Flags (may be combined):
//   -perms    show file permissions alongside each entry
//   -compact  single-line output: all entries on one row
//   -debug    dump all available metadata per entry

const sys = @import("syscall");
const io = @import("io");

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    var show_perms: bool = false;
    var compact: bool = false;
    var debug: bool = false;
    var dir_arg: ?[*:0]const u8 = null;

    var i: usize = 1;

    while (i < argc) : (i += 1) {

        const a = argv[i] orelse continue;
        const s = a[0..cstr_len(a)];

        if (str_eql(s, "-perms")) {
            show_perms = true;
        } else if (str_eql(s, "-compact")) {
            compact = true;
        } else if (str_eql(s, "-debug")) {
            debug = true;
        } else {
            dir_arg = a;
        }

    }

    var buf: [4096]u8 = undefined;

    const total = if (dir_arg) |d|
        sys.listfiles_in(&buf, d)
    else
        sys.listfiles(&buf);

    if (total == 0) {

        io.println("(no files)");
        sys.exit(0);

    }

    // Entry layout (7 NUL-terminated fields per entry):
    //   name\0  kind\0  size\0  perms\0  inode\0  owner\0  capacity\0
    //
    // perms is a decimal bitmask: bit0=read bit1=write bit2=exec bit3=delete

    var pos: usize = 0;
    var count: usize = 0;

    while (pos < total) {

        // --- name ---
        const name_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const name = buf[name_start..pos];
        if (pos < total) pos += 1;

        // --- kind ---
        const kind: u8 = if (pos < total) buf[pos] else 0;
        if (pos < total) pos += 1;
        if (pos < total and buf[pos] == 0) pos += 1; // kind NUL

        // --- size ---
        const size_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const size_str = buf[size_start..pos];
        if (pos < total) pos += 1;

        // --- perms ---
        const perms_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const perms_str = buf[perms_start..pos];
        if (pos < total) pos += 1;

        // --- inode ---
        const inode_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const inode_str = buf[inode_start..pos];
        if (pos < total) pos += 1;

        // --- owner ---
        const owner_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const owner_str = buf[owner_start..pos];
        if (pos < total) pos += 1;

        // --- capacity ---
        const cap_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const cap_str = buf[cap_start..pos];
        if (pos < total) pos += 1;

        if (name.len == 0) continue;

        if (compact) {

            if (count > 0) io.print("  ");
            io.print(name);
            if (kind == 'd') io.print("/");

        } else if (debug) {

            // Decode permissions bitmask.
            const pmask = parse_uint(perms_str);

            io.print("  ");
            io.print(name);
            pad_to(name.len, 22);

            if (kind == 'd') {
                io.print("<dir>  ");
            } else {
                io.print(size_str);
                io.print(" bytes  ");
            }

            io.print("inode=");
            io.print(inode_str);
            io.print("  owner=");
            io.print(owner_str);
            io.print("  cap=");
            io.print(cap_str);
            io.print("  ");
            print_perms(pmask);
            io.print("\r\n");

        } else if (show_perms) {

            const pmask = parse_uint(perms_str);

            io.print("  ");
            io.print(name);
            pad_to(name.len, 22);

            if (kind == 'd') {
                io.print("<dir>\r\n");
            } else {
                io.print(size_str);
                io.print(" bytes | ");
                print_perms(pmask);
                io.print("\r\n");
            }

        } else {

            // Default layout (unchanged).
            io.print("  ");
            io.print(name);
            pad_to(name.len, 22);

            if (kind == 'd') {
                io.println("<dir>");
            } else {
                io.print(size_str);
                io.println(" bytes");
            }

        }

        count += 1;

    }

    if (compact and count > 0) io.print("\r\n");

    if (count == 0) {

        io.println("(no files)");

    }

    sys.exit(0);

}

/// Print permissions as "+read -write +exec -delete" style.
fn print_perms(mask: usize) void {

    print_perm(mask & 1 != 0, "read");
    io.print(" ");
    print_perm(mask & 2 != 0, "write");
    io.print(" ");
    print_perm(mask & 4 != 0, "exec");
    io.print(" ");
    print_perm(mask & 8 != 0, "delete");

}

fn print_perm(set: bool, name: []const u8) void {

    if (set) {
        io.print("+");
    } else {
        io.print("-");
    }
    io.print(name);

}

/// Print spaces until `cur_len` reaches `target`.
fn pad_to(cur_len: usize, target: usize) void {

    var n = cur_len;

    while (n < target) : (n += 1) {
        io.print(" ");
    }

    io.print("  ");

}

fn parse_uint(s: []const u8) usize {

    var v: usize = 0;

    for (s) |c| {

        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');

    }

    return v;

}

fn cstr_len(s: [*:0]const u8) usize {

    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;

}

fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {
        if (x != y) return false;
    }

    return true;

}
