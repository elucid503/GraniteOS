// user/lib/io.zig - User-space I/O helpers built on syscalls

const sys = @import("syscall.zig");

/// Write a string to stdout.
pub fn print(s: []const u8) void {

    _ = sys.write(sys.STDOUT, s);

}

/// Write a string followed by \r\n to stdout.
pub fn println(s: []const u8) void {

    print(s);
    print("\r\n");

}

/// Write a 64-bit value as lowercase hex (no leading zeros, no prefix).
pub fn print_hex(value: u64) void {

    const digits = "0123456789abcdef";

    if (value == 0) {

        print("0");
        return;

    }

    var buf: [16]u8 = undefined;
    var pos: usize = buf.len;

    var v = value;

    while (v > 0) {

        pos -= 1;
        buf[pos] = digits[@intCast(v & 0xF)];

        v >>= 4;

    }

    print(buf[pos..]);

}

/// Write a single decimal integer to stdout.
pub fn print_int(value: usize) void {

    if (value == 0) {

        print("0");
        return;

    }

    var buf: [20]u8 = undefined;
    var pos: usize = buf.len;

    var v = value;

    while (v > 0) {

        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));

        v /= 10;

    }

    print(buf[pos..]);

}

/// Read one character from stdin. Blocks until a character is available.
pub fn read_char() u8 {

    var buf: [1]u8 = undefined;

    while (true) {

        const n = sys.read(sys.STDIN, &buf);

        if (n > 0) return buf[0];

    }

}

/// Read a line from stdin into buf (stops at \n or when buf is full).
/// Returns the slice of buf that was filled (not including the newline).
pub fn read_line(buf: []u8) []u8 {

    var pos: usize = 0;

    while (pos < buf.len) {

        const c = read_char();

        if (c == '\n' or c == '\r') break;

        buf[pos] = c;
        pos += 1;

    }

    return buf[0..pos];

}
