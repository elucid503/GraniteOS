// user/lib/wm.zig — Terminal window manager for split-pane UART layouts

const sys = @import("syscall");

pub const TERM_COLS: usize = 80;
pub const TERM_ROWS: usize = 24;

const FRAME_BUF_SIZE: usize = 4096;

pub const SepKind = enum { top, middle, bottom };

pub const PaneInfo = struct {

    col_start: usize,
    width: usize,

};

var split_col: usize = 0;
var active_panes: usize = 1;

var frame_buf: [FRAME_BUF_SIZE]u8 = undefined;
var frame_pos: usize = 0;

/// Configure a single full-width pane with no divider.
pub fn init_single() void {

    split_col = 0;
    active_panes = 1;

}

/// Configure two vertical panes with a divider at column `col`.
pub fn init_split(col: usize) void {

    split_col = col;
    active_panes = 2;

}

/// Return layout info for a pane by index.
pub fn pane(index: usize) PaneInfo {

    if (active_panes == 1) return .{ .col_start = 0, .width = TERM_COLS };
    if (index == 0) return .{ .col_start = 0, .width = split_col };

    return .{ .col_start = split_col + 1, .width = TERM_COLS - split_col - 1 };

}

/// Return the number of active panes.
pub fn pane_count() usize {

    return active_panes;

}

/// Return the divider column (0 when not split).
pub fn divider() usize {

    return split_col;

}

// Buffered output: accumulates bytes and flushes as a single write to stdout.

/// Reset the output buffer.
pub fn buf_reset() void {

    frame_pos = 0;

}

/// Append a string to the output buffer via bulk copy.
pub fn buf_str(s: []const u8) void {

    const avail = FRAME_BUF_SIZE - frame_pos;
    const n = @min(s.len, avail);

    if (n > 0) {

        @memcpy(frame_buf[frame_pos..][0..n], s[0..n]);
        frame_pos += n;

    }

}

/// Append a single byte to the output buffer.
pub fn buf_char(c: u8) void {

    if (frame_pos < FRAME_BUF_SIZE) {

        frame_buf[frame_pos] = c;
        frame_pos += 1;

    }

}

/// Append a decimal integer to the output buffer.
pub fn buf_int(value: usize) void {

    if (value == 0) {

        buf_char('0');
        return;

    }

    var num_buf: [20]u8 = undefined;
    var p: usize = 20;
    var v = value;

    while (v > 0) {

        p -= 1;
        num_buf[p] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;

    }

    buf_str(num_buf[p..20]);

}

/// Append a CSI cursor-move to (row, col), both 1-indexed.
pub fn buf_move(row: usize, col: usize) void {

    buf_str("\x1B[");
    buf_int(row);
    buf_char(';');
    buf_int(col);
    buf_char('H');

}

/// Append a CSI "clear to end of line" sequence.
pub fn buf_clear_eol() void {

    buf_str("\x1B[K");

}

/// Append a CSI "cursor home" (row 1, col 1) sequence.
pub fn buf_home() void {

    buf_str("\x1B[H");

}

/// Flush the output buffer to stdout as a single write, then reset.
pub fn flush() void {

    if (frame_pos > 0) {

        _ = sys.write(sys.STDOUT, frame_buf[0..frame_pos]);
        frame_pos = 0;

    }

}

// Box drawing via VT100 DEC Special Graphics character set.
// ESC(0 enters line-drawing mode; ESC(B returns to ASCII.
// In line-drawing mode: q=─  x=│  w=┬  v=┴  n=┼

/// Draw a full-width horizontal separator with an intersection at the divider column.
pub fn buf_separator(kind: SepKind) void {

    buf_str("\x1B(0"); // enter line-drawing mode

    var col: usize = 0;

    while (col < TERM_COLS) : (col += 1) {

        if (active_panes > 1 and col == split_col) {

            buf_char(switch (kind) {
                .top => 'w',    // ┬
                .middle => 'n', // ┼
                .bottom => 'v', // ┴
            });

        } else {

            buf_char('q'); // ─

        }

    }

    buf_str("\x1B(B"); // exit line-drawing mode
    buf_str("\r\n");

}

/// Draw a blank line with the vertical divider at the split column.
pub fn buf_divider_line() void {

    if (active_panes < 2) {

        buf_str("\r\n");
        return;

    }

    var i: usize = 0;

    while (i < split_col) : (i += 1) buf_char(' ');

    buf_str("\x1B(0x\x1B(B"); // │
    buf_str("\r\n");

}

/// Output the vertical divider character at the current cursor position.
pub fn buf_divider_char() void {

    if (active_panes < 2) return;

    buf_str("\x1B(0x\x1B(B"); // │

}

/// Read all output from `read_fd` (a pipe) and reprint it for pane 1, drawing
/// the vertical divider character at `split_col + 1` (1-indexed) before every
/// line of content (including the first).  Content follows at `col_start + 1`.
/// Bare `\r` is suppressed.  Always leaves the cursor on a fresh line at col 1.
pub fn relay_paned(read_fd: usize, col_start: usize) void {

    // Position: divider │ then pane-1 content column, before the first byte.

    buf_reset();
    buf_str("\x1B[");
    buf_int(split_col + 1); // 1-indexed divider column
    buf_char('G');
    buf_divider_char();
    buf_str("\x1B[");
    buf_int(col_start + 1); // 1-indexed content column
    buf_char('G');
    flush();

    var read_buf: [256]u8 = undefined;
    var line_buf: [TERM_COLS]u8 = undefined;
    var line_pos: usize = 0;

    while (true) {

        const n = sys.read(read_fd, &read_buf);
        if (n <= 0) break;

        for (read_buf[0..@as(usize, @intCast(n))]) |ch| {

            if (ch == '\r') continue;

            if (ch == '\n') {

                if (line_pos > 0) {
                    _ = sys.write(sys.STDOUT, line_buf[0..line_pos]);
                    line_pos = 0;
                }

                // New line: │ at divider, then move to content column.
                buf_reset();
                buf_str("\r\n");
                buf_str("\x1B[");
                buf_int(split_col + 1);
                buf_char('G');
                buf_divider_char();
                buf_str("\x1B[");
                buf_int(col_start + 1);
                buf_char('G');
                flush();
                continue;

            }

            if (line_pos < line_buf.len) {
                line_buf[line_pos] = ch;
                line_pos += 1;
            }

        }

    }

    // Flush any remaining partial line (no trailing │ — let prompt add it).

    if (line_pos > 0) _ = sys.write(sys.STDOUT, line_buf[0..line_pos]);

}

/// Read all output from `read_fd` (a pipe) and relay it for pane 0 (left side).
/// After every line, draws │ at split_col+1 (1-indexed) then \r\n so content
/// stays visually bounded by the divider.  Partial last lines also get │+\r\n
/// so the caller's prompt always starts at column 1.
pub fn relay_pane0(read_fd: usize) void {

    var read_buf: [256]u8 = undefined;
    var line_buf: [TERM_COLS]u8 = undefined;
    var line_pos: usize = 0;

    while (true) {

        const n = sys.read(read_fd, &read_buf);
        if (n <= 0) break;

        for (read_buf[0..@as(usize, @intCast(n))]) |ch| {

            if (ch == '\r') continue;

            if (ch == '\n') {

                if (line_pos > 0) {
                    _ = sys.write(sys.STDOUT, line_buf[0..line_pos]);
                    line_pos = 0;
                }

                buf_reset();
                buf_str("\x1B[");
                buf_int(split_col + 1); // 1-indexed divider column
                buf_char('G');
                buf_divider_char();
                buf_str("\r\n");
                flush();
                continue;

            }

            if (line_pos < line_buf.len) {
                line_buf[line_pos] = ch;
                line_pos += 1;
            }

        }

    }

    // Flush partial last line with trailing │, always end at col 1.

    if (line_pos > 0) {
        _ = sys.write(sys.STDOUT, line_buf[0..line_pos]);
    }

    buf_reset();
    buf_str("\x1B[");
    buf_int(split_col + 1);
    buf_char('G');
    buf_divider_char();
    buf_str("\r\n");
    flush();

}
