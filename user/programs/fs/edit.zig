// user/programs/fs/edit.zig — Interactive text editor with nano-like TUI; pipe-in mode when stdin is redirected.

const sys = @import("syscall");
const io = @import("io");

// Terminal layout (assumes 80x24 VT100-compatible terminal).

const TERM_ROWS: usize = 24;
const CONTENT_ROWS: usize = TERM_ROWS - 4; // header (2) + footer (2) = 20 content rows
const FILE_MAX: usize = 4095;              // max editable bytes (one byte reserved for safety)

var content: [FILE_MAX + 1]u8 = undefined;
var content_len: usize = 0;
var cursor_pos: usize = 0;
var scroll_row: usize = 0;

export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc < 2) {

        io.println("usage: edit <filename>");
        sys.exit(1);

    }

    const file_name_z = argv[1].?;

    if (!sys.isatty(sys.STDIN)) {

        // Piped mode: read from stdin and write directly to the file.

        const fd = sys.open(file_name_z, sys.OPEN_READWRITE);

        if (fd < 0) {

            io.println("error: cannot open file");
            sys.exit(1);

        }

        var buf: [512]u8 = undefined;

        while (true) {

            const n = sys.read(sys.STDIN, &buf);
            if (n <= 0) break;
            _ = sys.write(@intCast(fd), buf[0..@intCast(n)]);

        }

        _ = sys.close(@intCast(fd));
        sys.exit(0);

    }

    // Interactive TUI mode.

    const name_len = cstr_len(file_name_z);
    run_tui(file_name_z[0..name_len], file_name_z);
    sys.exit(0);

}

// Interactive TUI: load file, edit, save on Alt+S, exit on Alt+C.
fn run_tui(filename: []const u8, file_name_z: [*:0]const u8) void {

    // Load existing file content.

    content_len = 0;
    cursor_pos = 0;
    scroll_row = 0;

    const fd_r = sys.open(file_name_z, sys.OPEN_READ);

    if (fd_r >= 0) {

        const n = sys.read(@intCast(fd_r), content[0..FILE_MAX]);
        if (n > 0) content_len = @intCast(n);
        _ = sys.close(@intCast(fd_r));

    }

    io.print("\x1B[2J"); // clear screen once at entry
    draw(filename);

    while (true) {

        const c = io.read_char();

        // ESC: Alt shortcuts or arrow keys.

        if (c == 0x1B) {

            const c2 = io.read_char();

            // Alt+C: exit without saving.

            if (c2 == 'c') {

                io.print("\x1B[2J\x1B[H");
                return;

            }

            // Alt+S: save and exit.

            if (c2 == 's') {

                save(file_name_z);
                io.print("\x1B[2J\x1B[H");
                return;

            }

            // Arrow keys via CSI (ESC [ X) or SS3 (ESC O X).

            if (c2 == '[' or c2 == 'O') {

                switch (io.read_char()) {
                    'A' => move_up(),
                    'B' => move_down(),
                    'C' => move_right(),
                    'D' => move_left(),
                    else => {},
                }

            }

            draw(filename);
            continue;

        }

        // Backspace / DEL.

        if (c == 0x08 or c == 0x7F) {

            delete_before();
            draw(filename);
            continue;

        }

        // Enter: insert a newline.

        if (c == '\r' or c == '\n') {

            insert_char('\n');
            draw(filename);
            continue;

        }

        // Printable ASCII.

        if (c >= 0x20 and c < 0x7F) {

            insert_char(c);
            draw(filename);
            continue;

        }

    }

}

// Save the content buffer to a file, handling permissions for delete+recreate.
fn save(file_name_z: [*:0]const u8) void {

    // Grant write+delete permissions on the existing file so we can replace it.

    _ = sys.chmod(file_name_z, 0b1011); // read + write + delete
    _ = sys.delete(file_name_z);

    // Create a fresh file and grant write permission.

    _ = sys.create(file_name_z);
    _ = sys.chmod(file_name_z, 0b0011); // read + write

    const fd_w = sys.open(file_name_z, sys.OPEN_WRITE);

    if (fd_w >= 0) {

        _ = sys.write(@intCast(fd_w), content[0..content_len]);
        _ = sys.close(@intCast(fd_w));

    }

}

// Buffered screen redraw: build entire frame in wm buffer, flush as single write.
// Uses cursor-home instead of screen-clear to eliminate flicker.
fn draw(filename: []const u8) void {

    const rc = cursor_row_col();

    // Adjust viewport so cursor stays visible.

    if (rc.row < scroll_row) scroll_row = rc.row;
    if (rc.row >= scroll_row + CONTENT_ROWS) scroll_row = rc.row - CONTENT_ROWS + 1;

    // Cursor to top-left without clearing
    io.print("\x1B[H");

    // Header: "filename | N Bytes" then blank line.

    io.print(filename);
    io.print(" | ");
    io.print_int(content_len);
    io.print(" Bytes");
    io.print("\x1B[K");
    io.print("\r\n");
    io.print("\x1B[K");
    io.print("\r\n");

    // Skip to scroll_row.

    var pos: usize = 0;
    var skip: usize = 0;

    while (skip < scroll_row and pos < content_len) {

        if (content[pos] == '\n') skip += 1;
        pos += 1;

    }

    // Render CONTENT_ROWS logical lines.

    var lines: usize = 0;

    while (lines < CONTENT_ROWS) : (lines += 1) {

        const line_start = pos;

        while (pos < content_len and content[pos] != '\n') pos += 1;

        if (pos > line_start) io.print(content[line_start..pos]);

        io.print("\x1B[K");
        io.print("\r\n");

        if (pos < content_len) pos += 1; // step past '\n'

    }

    // Footer.

    io.print("\x1B[K");
    io.print("\r\n");
    io.print("Exit (Alt+C) | Save (Alt+S)");
    io.print("\x1B[K");

    // Position cursor inside the content area.
    // Content starts at display row 3 (1-indexed): row 1 = header, row 2 = blank.

    const disp_row: usize = 3 + (if (rc.row >= scroll_row) rc.row - scroll_row else 0);
    const disp_col: usize = rc.col + 1;

    io.print("\x1B[");
    io.print_int(disp_row);
    io.print(";");
    io.print_int(disp_col);
    io.print("H");

}

// Compute logical (row, col) of cursor_pos by scanning from offset 0.
const RowCol = struct { row: usize, col: usize };

fn cursor_row_col() RowCol {

    var row: usize = 0;
    var col: usize = 0;

    for (content[0..cursor_pos]) |ch| {

        if (ch == '\n') {

            row += 1;
            col = 0;

        } else {

            col += 1;

        }

    }

    return .{ .row = row, .col = col };

}

// Return byte offset of the start of logical row `target`.
fn row_start(target: usize) usize {

    if (target == 0) return 0;

    var row: usize = 0;

    for (content[0..content_len], 0..) |ch, i| {

        if (ch == '\n') {

            row += 1;
            if (row == target) return i + 1;

        }

    }

    return content_len;

}

// Return byte count of logical row `target` (excluding the '\n').
fn row_len(target: usize) usize {

    const start = row_start(target);
    var end = start;

    while (end < content_len and content[end] != '\n') end += 1;

    return end - start;

}

fn move_up() void {

    const rc = cursor_row_col();
    if (rc.row == 0) return;
    const prev_start = row_start(rc.row - 1);
    const prev_len = row_len(rc.row - 1);
    cursor_pos = prev_start + @min(rc.col, prev_len);

}

fn move_down() void {

    const rc = cursor_row_col();
    const next_row = rc.row + 1;
    const next_start = row_start(next_row);
    if (next_start >= content_len and content_len > 0 and content[content_len - 1] != '\n') {

        // No next row exists; stay put.
        return;

    }

    if (next_start > content_len) return;

    const next_len = row_len(next_row);
    cursor_pos = next_start + @min(rc.col, next_len);

}

fn move_left() void {

    if (cursor_pos > 0) cursor_pos -= 1;

}

fn move_right() void {

    if (cursor_pos < content_len) cursor_pos += 1;

}

fn insert_char(ch: u8) void {

    if (content_len >= FILE_MAX) return;

    var i = content_len;

    while (i > cursor_pos) : (i -= 1) content[i] = content[i - 1];

    content[cursor_pos] = ch;
    content_len += 1;
    cursor_pos += 1;

}

fn delete_before() void {

    if (cursor_pos == 0) return;

    cursor_pos -= 1;

    var i = cursor_pos;

    while (i < content_len - 1) : (i += 1) content[i] = content[i + 1];

    content_len -= 1;

}

fn cstr_len(s: [*:0]const u8) usize {

    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;

}
