// user/help.zig - Lists available programs by category

const sys = @import("syscall");
const io = @import("io");

export fn _start() noreturn {

    io.println("\r\nGraniteOS - Available Programs\r\n");

    var buf: [2048]u8 = undefined;
    const total = sys.listprogs(&buf);

    if (total == 0) {

        sys.exit(0); // this should not really happen

    }

    // Each entry: category\0 name\0 description\0. Category is repeated per entry; we print it only when it changes.
    var pos: usize = 0;
    var current_cat: [32]u8 = undefined;
    var current_cat_len: usize = 0;
    var first = true;

    while (pos < total) {

        const cat_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const category = buf[cat_start..pos];
        pos += 1;

        const name_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const name = buf[name_start..pos];
        pos += 1;

        const desc_start = pos;
        while (pos < total and buf[pos] != 0) pos += 1;
        const desc = buf[desc_start..pos];
        pos += 1;

        if (name.len == 0) continue;

        if (category.len != current_cat_len or !eqslice(category, current_cat[0..current_cat_len])) {

            if (!first) io.println("");
            first = false;

            io.println(category);
            @memcpy(current_cat[0..category.len], category);

            current_cat_len = category.len;

        }

        io.print("  ");
        io.print(name);

        var padding: usize = 0;

        while (padding + name.len < 12) : (padding += 1) {
            io.print(" ");
        }

        io.print("  ");
        io.println(desc);

    }

    io.println("");
    sys.exit(0);

}

fn eqslice(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
