// user/basalt.zig - BASALT: Basic Adaptive Shell And Lightweight Terminal

const sys = @import("syscall");
const io = @import("io");

const MAX_LINE: usize = 256;
const MAX_PIPE_STAGES: usize = 8;
const MAX_ARGS: usize = 16;

// Command history: doubly-linked list with max 25 entries stored in a fixed array.
// prev -> toward newer (head), next -> toward older (tail).

const HISTORY_MAX: usize = 25;
const NONE: usize = HISTORY_MAX; // sentinel for null index

const HistoryNode = struct {

    cmd: [MAX_LINE]u8,
    len: usize,

    prev: usize, // toward newer / head
    next: usize, // toward older / tail

};

// doubly-linked list for history

var h_nodes: [HISTORY_MAX]HistoryNode = undefined;
var h_head: usize = NONE; // most recent entry
var h_tail: usize = NONE; // oldest entry
var h_count: usize = 0;

// Split-pane state.

const MAX_PANES: usize = 2;
const PANE0_COLS: usize = 40; // columns for pane 0 (0-indexed cols 0-39)
const PANE1_COLS: usize = 38; // columns for pane 1 (0-indexed cols 42-79, after "| ")
const MAX_CWD_DISP: usize = 10; // max chars of CWD shown in split prompt

var split_mode: bool = false;
var active_pane: usize = 0;
var pane_cwd: [MAX_PANES][257]u8 = undefined;
var pane_cwd_len: [MAX_PANES]usize = .{0} ** MAX_PANES;
var pane_h_nodes: [MAX_PANES][HISTORY_MAX]HistoryNode = undefined;
var pane_h_head: [MAX_PANES]usize = .{NONE} ** MAX_PANES;
var pane_h_tail: [MAX_PANES]usize = .{NONE} ** MAX_PANES;
var pane_h_count: [MAX_PANES]usize = .{0} ** MAX_PANES;
var pane_switched: bool = false;      // Alt+S: switch to other pane
var pane_new_requested: bool = false; // Alt+N: open split (any mode)
var pane_close_requested: bool = false; // Alt+C: close active pane

/// Push a command onto the front of the history list.
/// Evicts the oldest entry when full. Skips duplicate of the most recent entry.
fn history_push(cmd: []const u8) void {

    if (cmd.len == 0) return;

    // Skip if identical to most recent entry.

    if (h_head != NONE and str_eql(cmd, h_nodes[h_head].cmd[0..h_nodes[h_head].len])) return;

    var slot: usize = undefined;

    if (h_count < HISTORY_MAX) {

        slot = h_count;
        h_count += 1;

    } else {

        // Evict oldest (tail) and reuse its slot.

        slot = h_tail;
        const new_tail = h_nodes[slot].prev;

        if (new_tail != NONE) {

            h_nodes[new_tail].next = NONE;

        }

        h_tail = new_tail;

    }

    // Fills the slot

    const copy_len = if (cmd.len < MAX_LINE) cmd.len else MAX_LINE;

    @memcpy(h_nodes[slot].cmd[0..copy_len], cmd[0..copy_len]);

    h_nodes[slot].len = copy_len;
    h_nodes[slot].prev = NONE;
    h_nodes[slot].next = h_head;

    if (h_head != NONE) {

        h_nodes[h_head].prev = slot;

    }

    h_head = slot;

    if (h_tail == NONE) {

        h_tail = slot;

    }

}

export fn _start() noreturn {

    io.println("BASALT ......... Ready\r\n");
    io.println("Type 'help' for available commands, 'exit' to relaunch.");
    io.println("Alt+N: new pane  Alt+S: switch pane  Alt+C: close pane\r\n");

    var line_buf: [MAX_LINE]u8 = undefined;

    while (true) {

        if (split_mode) {

            run_split_iteration(&line_buf);

        } else {

            print_prompt();

            const line = read_line_impl(&line_buf, .{ .max_width = MAX_LINE - 1, .split_tab = false });

            if (pane_new_requested) {

                pane_new_requested = false;
                enter_split_mode();
                continue;

            }

            if (line.len == 0) continue;

            history_push(line);

            if (str_eql(line, "exit")) {

                io.println("Exiting BASALT...");
                sys.exit(0);

            }

            execute(line);

        }

    }

}

// One iteration of the split-pane loop: print split prompt, read input, execute.
fn run_split_iteration(line_buf: *[MAX_LINE]u8) void {

    // Ensure the process CWD matches the active pane.

    chdir_pane(active_pane);

    print_split_prompt();

    pane_switched = false;

    const max_w = split_input_width(active_pane);
    const line = read_line_impl(line_buf, .{ .max_width = max_w, .split_tab = true });

    // Handle pane-control keys before inspecting the line.

    if (pane_new_requested) {

        pane_new_requested = false;
        // Already in split mode; ignore.
        return;

    }

    if (pane_switched) {

        save_pane_cwd(active_pane);
        save_pane_history(active_pane);
        print_divider_line();

        active_pane = 1 - active_pane;

        load_pane_history(active_pane);
        chdir_pane(active_pane);
        return;

    }

    if (pane_close_requested) {

        pane_close_requested = false;
        save_pane_cwd(active_pane);
        save_pane_history(active_pane);
        split_mode = false;
        io.println("Split closed.");
        return;

    }

    if (line.len == 0) return;

    history_push(line);

    if (str_eql(line, "exit")) {

        io.println("Exiting BASALT...");
        sys.exit(0);

    }

    execute(line);

    // Save CWD in case a 'cd' ran.

    save_pane_cwd(active_pane);
    save_pane_history(active_pane);

    // Print divider lines before the next prompt so the split is visible.

    print_divider_line();
    print_divider_line();

}

// Print the split prompt: both pane prompts on one line, cursor in active pane.
fn print_split_prompt() void {

    const d0 = get_display_cwd(0);
    const d1 = get_display_cwd(1);

    // Prompt text length: "basalt [cwd]> " = 8 + cwd + 3 = 11 + cwd_len
    const p0_len = 11 + d0.len;
    const p1_len = 11 + d1.len;

    // Clear current line.

    io.print("\r\x1B[2K");

    // Pane 0 prompt.

    io.print("basalt [");
    io.print(d0);
    io.print("]> ");

    // Pad to column 40 (0-indexed) where the divider sits.

    var col: usize = p0_len;

    while (col < PANE0_COLS) : (col += 1) io.print(" ");

    // Divider.

    io.print("| ");

    // Pane 1 prompt (both always use the same "basalt [cwd]> " form).

    io.print("basalt [");
    io.print(d1);
    io.print("]> ");

    // Position cursor at the active pane's input start using CHA (CSI <n> G).

    if (active_pane == 0) {

        // Move back to after pane 0's prompt: ANSI col p0_len+1 (1-indexed).

        io.print("\x1B[");
        io.print_int(p0_len + 1);
        io.print("G");

    } else {

        // Pane 1 starts at ANSI col 43 (0-indexed col 42, after "| ").
        // Cursor is already at ANSI col 43 + p1_len — already at the right place.
        _ = p1_len; // suppress unused warning; cursor is already positioned

    }

}

// Print a single `|` separator line at the pane divider column.
fn print_divider_line() void {

    var i: usize = 0;
    while (i < PANE0_COLS) : (i += 1) io.print(" ");
    io.print("|\r\n");

}

// Maximum input characters for a pane given its CWD display length.
fn split_input_width(pane: usize) usize {

    const d = get_display_cwd(pane);
    const prompt_len = 11 + d.len;
    const pane_cols: usize = if (pane == 0) PANE0_COLS - 1 else PANE1_COLS - 1;

    if (prompt_len >= pane_cols) return 2;

    return pane_cols - prompt_len;

}

// Return a slice of the pane's CWD, truncated to MAX_CWD_DISP chars from the right.
fn get_display_cwd(pane: usize) []const u8 {

    const len = pane_cwd_len[pane];

    if (len == 0) return "/";

    const cwd = pane_cwd[pane][0..len];

    return if (len <= MAX_CWD_DISP) cwd else cwd[len - MAX_CWD_DISP ..];

}

// Write the current process CWD into pane_cwd[pane].
fn save_pane_cwd(pane: usize) void {

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);

    if (n > 0) {

        const len: usize = @as(usize, @intCast(n)) - 1; // exclude NUL
        @memcpy(pane_cwd[pane][0..len], buf[0..len]);
        pane_cwd_len[pane] = len;

    }

}

// chdir to pane_cwd[pane] (NUL-terminate inline before passing to kernel).
fn chdir_pane(pane: usize) void {

    pane_cwd[pane][pane_cwd_len[pane]] = 0;
    _ = sys.chdir(@ptrCast(&pane_cwd[pane]));

}

// Copy current global history state into the pane's saved history.
fn save_pane_history(pane: usize) void {

    pane_h_nodes[pane] = h_nodes;
    pane_h_head[pane] = h_head;
    pane_h_tail[pane] = h_tail;
    pane_h_count[pane] = h_count;

}

// Restore a pane's saved history into the global history state.
fn load_pane_history(pane: usize) void {

    h_nodes = pane_h_nodes[pane];
    h_head = pane_h_head[pane];
    h_tail = pane_h_tail[pane];
    h_count = pane_h_count[pane];

}

// Activate split-pane mode.
fn enter_split_mode() void {

    // Save current CWD and history to both panes.

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);
    var cwd_len: usize = 0;

    if (n > 1) {

        cwd_len = @as(usize, @intCast(n)) - 1;
        @memcpy(pane_cwd[0][0..cwd_len], buf[0..cwd_len]);
        @memcpy(pane_cwd[1][0..cwd_len], buf[0..cwd_len]);

    } else {

        pane_cwd[0][0] = '/';
        pane_cwd[1][0] = '/';
        cwd_len = 1;

    }

    pane_cwd_len[0] = cwd_len;
    pane_cwd_len[1] = cwd_len;

    save_pane_history(0);
    save_pane_history(1);

    active_pane = 0;
    split_mode = true;

    io.println("Split: Alt+S to switch  Alt+C to close");

}

/// Parses and executes a command line, handling pipes if present.
fn execute(line: []const u8) void {

    // Split by '|' into stages.

    var stages: [MAX_PIPE_STAGES][]const u8 = undefined;
    var stage_count: usize = 0;

    var start: usize = 0;

    for (line, 0..) |c, i| {

        if (c == '|') {

            if (stage_count >= MAX_PIPE_STAGES) {

                io.println("basalt: too many pipe stages");
                return;

            }

            stages[stage_count] = trim(line[start..i]);
            stage_count += 1;
            start = i + 1;

        }

    }

    // Last (or only) segment.

    if (stage_count >= MAX_PIPE_STAGES) {

        io.println("basalt: too many pipe stages");
        return;

    }

    stages[stage_count] = trim(line[start..]);
    stage_count += 1;

    // Validate: no empty stages.

    for (stages[0..stage_count]) |s| {

        if (s.len == 0) {

            io.println("basalt: empty command in pipeline");
            return;

        }

    }

    if (stage_count == 1) {

        if (try_builtin(stages[0])) return;

        run_single(stages[0]);

    } else {

        run_pipeline(stages[0..stage_count]);

    }

}

/// Handles `cd`, `path`, `new`, and `close` in the shell process (must not fork).
fn try_builtin(line: []const u8) bool {

    const t = trim(line);

    if (str_eql(t, "location")) {

        builtin_location();
        return true;

    }

    if (str_eql(t, "new")) {

        enter_split_mode();
        return true;

    }

    if (t.len < 2 or t[0] != 'c' or t[1] != 'd') return false;

    if (t.len == 2) {

        builtin_cd("");
        return true;

    }

    if (t[2] != ' ') return false;

    builtin_cd(trim(t[3..]));
    return true;

}

fn builtin_location() void {

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);

    if (n < 0) {

        io.println("location: cannot read current directory");
        return;

    }

    const len: usize = @intCast(n);

    if (len <= 1) {

        io.println("/");
        return;

    }

    io.println(buf[0 .. len - 1]);

}

/// `basalt [cwd]> ` using the kernel working directory for this process.
fn print_prompt() void {

    var cwd_buf: [256]u8 = undefined;
    const n = sys.getcwd(&cwd_buf);

    io.print("basalt ");

    if (n < 0) {

        io.print("[?]");

    } else {

        const len: usize = @intCast(n);

        if (len <= 1) {

            io.print("[/]");

        } else {

            io.print("[");
            io.print(cwd_buf[0 .. len - 1]);
            io.print("]");

        }

    }

    io.print("> ");

}

fn builtin_cd(arg: []const u8) void {

    var path_buf: [MAX_LINE]u8 = undefined;

    if (arg.len == 0) {

        path_buf[0] = '/';
        path_buf[1] = 0;

    } else {

        if (arg.len + 1 > path_buf.len) {

            io.println("cd: path too long");
            return;

        }

        @memcpy(path_buf[0..arg.len], arg);
        path_buf[arg.len] = 0;

    }

    const r = sys.chdir(@ptrCast(&path_buf));

    if (r < 0) {

        io.println("cd: no such directory or not a directory");

    }

}

/// Run a single command (no pipes).
fn run_single(cmd: []const u8) void {

    const child = sys.fork();

    if (child < 0) {

        io.println("basalt: fork failed");
        return;

    }

    if (child == 0) exec_cmd(cmd);

    _ = sys.waitpid(@intCast(child));

}

/// Run a pipeline of commands connected by pipes.
fn run_pipeline(stages: []const []const u8) void {

    var pipe_fds: [MAX_PIPE_STAGES - 1][2]usize = undefined;
    var child_pids: [MAX_PIPE_STAGES]usize = undefined;

    // Create all pipes first.

    for (0..stages.len - 1) |i| {

        if (sys.pipe(&pipe_fds[i]) < 0) {

            io.println("basalt: pipe creation failed");

            for (0..i) |j| {
                _ = sys.close(pipe_fds[j][0]);
                _ = sys.close(pipe_fds[j][1]);
            }

            return;

        }

    }

    // Fork each stage.

    for (stages, 0..) |cmd, i| {

        const child = sys.fork();

        if (child < 0) {

            io.println("basalt: fork failed in pipeline");
            break;

        }

        if (child == 0) {

            // Connect stdin to previous pipe's read end.

            if (i > 0) {

                _ = sys.dup2(pipe_fds[i - 1][0], 0);

            }

            // Connect stdout to current pipe's write end.

            if (i < stages.len - 1) {

                _ = sys.dup2(pipe_fds[i][1], 1);

            }

            // Close all pipe fds in the child.

            for (0..stages.len - 1) |j| {

                _ = sys.close(pipe_fds[j][0]);
                _ = sys.close(pipe_fds[j][1]);

            }

            exec_cmd(cmd);

        }

        child_pids[i] = @intCast(child);

    }

    // Parent: close all pipe fds.

    for (0..stages.len - 1) |j| {
        _ = sys.close(pipe_fds[j][0]);
        _ = sys.close(pipe_fds[j][1]);
    }

    // Wait for all children.

    for (0..stages.len) |i| {

        _ = sys.waitpid(child_pids[i]);

    }

}

/// Parse a command string into argv and exec. Called in the child after fork.
/// Does not return on success; prints an error and exits on failure.
fn exec_cmd(cmd: []const u8) noreturn {

    var args_buf: [MAX_LINE]u8 = undefined;

    if (cmd.len >= args_buf.len) {

        io.println("basalt: command too long");
        sys.exit(1);

    }

    @memcpy(args_buf[0..cmd.len], cmd);

    var argv: [MAX_ARGS + 1]?[*:0]const u8 = .{null} ** (MAX_ARGS + 1);
    var argc: usize = 0;

    var i: usize = 0;

    while (i < cmd.len and argc < MAX_ARGS) {

        // Skip spaces.

        while (i < cmd.len and args_buf[i] == ' ') i += 1;

        if (i >= cmd.len) break;

        // Mark word start.

        const word_start = i;

        while (i < cmd.len and args_buf[i] != ' ') i += 1;

        // Null-terminate this word in-place.

        args_buf[i] = 0;

        argv[argc] = @ptrCast(&args_buf[word_start]);
        argc += 1;

        if (i < cmd.len) i += 1;

    }

    if (argc == 0) sys.exit(0);

    _ = sys.execve(argv[0].?, &argv);

    // Failed, print error and exit.

    io.print("basalt: unknown command: ");
    io.println(first_word(cmd));
    sys.exit(1);

}

// Line reading

/// Erase `n` characters from the terminal line by printing backspace-space-backspace sequences.
fn erase_chars(n: usize) void {

    var i: usize = 0;

    while (i < n) : (i += 1) {

        io.print("\x08 \x08");

    }

}

/// Replace the current terminal line with `new_cmd`.
/// Moves the cursor to end-of-line first so erase works regardless of cursor position.
fn replace_line(buf: []u8, pos: *usize, line_len: *usize, new_cmd: []const u8) void {

    // Move cursor to end.
    var k = pos.*;
    while (k < line_len.*) : (k += 1) io.print("\x1B[C");

    erase_chars(line_len.*);

    const copy_len = if (new_cmd.len < buf.len) new_cmd.len else buf.len - 1;

    @memcpy(buf[0..copy_len], new_cmd[0..copy_len]);
    pos.* = copy_len;
    line_len.* = copy_len;

    io.print(buf[0..copy_len]);

}

// Configuration for read_line_impl.
const ReadConfig = struct {
    max_width: usize,
    split_tab: bool,
};

/// Read a line from stdin with full editing support.
/// In split mode (split_tab=true): Tab sets pane_switched=true and returns empty.
/// max_width limits the number of typeable characters.
fn read_line_impl(buf: []u8, config: ReadConfig) []u8 {

    const effective_max = @min(config.max_width, buf.len - 1);
    var pos: usize = 0;
    var line_len: usize = 0;
    var nav_cursor: usize = NONE;
    var saved_buf: [MAX_LINE]u8 = undefined;
    var saved_len: usize = 0;

    while (true) {

        const c = io.read_char();

        // Enter

        if (c == '\r' or c == '\n') {

            io.print("\r\n");
            return buf[0..line_len];

        }

        // Backspace / DEL: remove the char to the left of the cursor.

        if (c == 0x08 or c == 0x7F) {

            if (pos > 0) {

                pos -= 1;
                line_len -= 1;

                // Shift buf[pos+1..line_len+1] left by one.

                var k: usize = pos;
                while (k < line_len) : (k += 1) buf[k] = buf[k + 1];

                // Move cursor back, redraw tail, erase the now-extra char, restore cursor.

                io.print("\x08");
                io.print(buf[pos..line_len]);
                io.print(" ");

                var back: usize = line_len - pos + 1;
                while (back > 0) : (back -= 1) io.print("\x08");

            }

            continue;

        }

        // ESC: ANSI escape sequences (arrow keys).
        // Handles CSI (ESC [ X) and SS3 (ESC O X) for up/down/left/right.

        if (c == 0x1B) {

            const c2 = io.read_char();

            // Alt+N: open a new pane (works in any mode).

            if (c2 == 'n') {

                io.print("\r\n");
                pane_new_requested = true;
                return buf[0..0];

            }

            // Alt+S: switch pane (split mode only).

            if (c2 == 's' and config.split_tab) {

                io.print("\r\n");
                pane_switched = true;
                return buf[0..0];

            }

            // Alt+C: close active pane (split mode only).

            if (c2 == 'c' and config.split_tab) {

                io.print("\r\n");
                pane_close_requested = true;
                return buf[0..0];

            }

            if (c2 == '[' or c2 == 'O') {

                const c3 = io.read_char();

                if (c3 == 'A') {

                    // Up arrow: older history entry.

                    if (h_head == NONE) { continue; }

                    if (nav_cursor == NONE) {

                        @memcpy(saved_buf[0..line_len], buf[0..line_len]);
                        saved_len = line_len;
                        nav_cursor = h_head;

                    } else {

                        const older = h_nodes[nav_cursor].next;
                        if (older == NONE) { continue; }
                        nav_cursor = older;

                    }

                    const src = h_nodes[nav_cursor].cmd[0..h_nodes[nav_cursor].len];
                    const capped = src[0..@min(src.len, effective_max)];
                    replace_line(buf, &pos, &line_len, capped);

                } else if (c3 == 'B') {

                    // Down arrow: newer history entry.

                    if (nav_cursor == NONE) { continue; }

                    const newer = h_nodes[nav_cursor].prev;

                    if (newer == NONE) {

                        replace_line(buf, &pos, &line_len, saved_buf[0..saved_len]);
                        nav_cursor = NONE;

                    } else {

                        nav_cursor = newer;
                        const src = h_nodes[nav_cursor].cmd[0..h_nodes[nav_cursor].len];
                        const capped = src[0..@min(src.len, effective_max)];
                        replace_line(buf, &pos, &line_len, capped);

                    }

                } else if (c3 == 'C') {

                    // Right arrow: move cursor right.

                    if (pos < line_len) {

                        pos += 1;
                        io.print("\x1B[C");

                    }

                } else if (c3 == 'D') {

                    // Left arrow: move cursor left.

                    if (pos > 0) {

                        pos -= 1;
                        io.print("\x1B[D");

                    }

                }

            }

            continue;

        }

        // Tab: always complete (same in both modes).

        if (c == 0x09) {

            while (pos < line_len) : (pos += 1) io.print("\x1B[C");

            tab_complete(buf, &pos);

            line_len = pos;
            nav_cursor = NONE;

            continue;

        }

        // Ignore other non-printable characters.

        if (c < 0x20) continue;

        nav_cursor = NONE;

        if (line_len >= effective_max) continue; // buffer or width full

        // Insert char at cursor: shift buf[pos..line_len] right by one.

        var k: usize = line_len;
        while (k > pos) : (k -= 1) buf[k] = buf[k - 1];

        buf[pos] = c;
        line_len += 1;

        // Print from cursor to end of line, then reposition cursor to pos+1.

        io.print(buf[pos..line_len]);
        pos += 1;

        var back: usize = line_len - pos;
        while (back > 0) : (back -= 1) io.print("\x08");

    }

}

// Tab completion

/// Complete the current partial word in buf as a directory path.
/// Splits the trailing word at the last `/` to get a dir and a name prefix,
/// lists that directory, and filters for directories matching the prefix.
/// One match: appends the rest of the name and a trailing `/`.
/// Multiple matches: prints the options on a new line, then reprints the prompt.
fn tab_complete(buf: []u8, pos: *usize) void {

    // Find the start of the current word (scan back past non-space chars).

    var word_start = pos.*;

    while (word_start > 0 and buf[word_start - 1] != ' ') {
        word_start -= 1;
    }

    const word = buf[word_start..pos.*];

    // Split word at the last `/` to get the directory and the name prefix.

    var slash_pos: ?usize = null;

    for (word, 0..) |ch, i| {
        if (ch == '/') slash_pos = i;
    }

    const dir_part: []const u8 = if (slash_pos) |sp| word[0 .. sp + 1] else "";
    const prefix: []const u8 = if (slash_pos) |sp| word[sp + 1 ..] else word;

    // Build a null-terminated path for the directory to list.

    var dir_buf: [MAX_LINE]u8 = undefined;
    var dir_path: ?[*:0]const u8 = null;

    if (dir_part.len > 0) {

        @memcpy(dir_buf[0..dir_part.len], dir_part);
        dir_buf[dir_part.len] = 0;
        dir_path = @ptrCast(&dir_buf);

    }

    // List the target directory.

    var list_buf: [4096]u8 = undefined;
    const list_n = sys.listfiles_in(&list_buf, dir_path);

    // Collect directories whose names start with `prefix`.

    const MAX_MATCHES = 16;
    const NAME_MAX = 32;

    var matches: [MAX_MATCHES][NAME_MAX]u8 = undefined;
    var match_lens: [MAX_MATCHES]usize = undefined;
    var match_count: usize = 0;

    var i: usize = 0;

    while (i < list_n and match_count < MAX_MATCHES) {

        // Entry layout: name\0 kind_char\0 size\0 perms\0 inode\0 owner\0 capacity\0

        const name_start = i;

        while (i < list_n and list_buf[i] != 0) i += 1;

        const name = list_buf[name_start..i];
        i += 1; // past name NUL

        const kind = if (i < list_n) list_buf[i] else 0;
        i += 1; // past kind char
        if (i < list_n) i += 1; // past kind NUL

        // Skip size string.

        while (i < list_n and list_buf[i] != 0) i += 1;
        if (i < list_n) i += 1; // past size NUL

        // Skip perms, inode, owner, capacity strings.

        while (i < list_n and list_buf[i] != 0) i += 1;
        if (i < list_n) i += 1;
        while (i < list_n and list_buf[i] != 0) i += 1;
        if (i < list_n) i += 1;
        while (i < list_n and list_buf[i] != 0) i += 1;
        if (i < list_n) i += 1;
        while (i < list_n and list_buf[i] != 0) i += 1;
        if (i < list_n) i += 1;

        if (kind != 'd') continue;
        if (name.len < prefix.len) continue;
        if (!starts_with(name, prefix)) continue;

        const copy_len = if (name.len < NAME_MAX) name.len else NAME_MAX - 1;
        @memcpy(matches[match_count][0..copy_len], name[0..copy_len]);
        match_lens[match_count] = copy_len;
        match_count += 1;

    }

    if (match_count == 0) return;

    if (match_count == 1) {

        // Append the remaining characters of the single match, then `/`.

        const rest = matches[0][prefix.len..match_lens[0]];
        const slash: []const u8 = "/";

        if (pos.* + rest.len + 1 < buf.len) {

            @memcpy(buf[pos.*..][0..rest.len], rest);
            pos.* += rest.len;
            buf[pos.*] = '/';
            pos.* += 1;
            io.print(rest);
            io.print(slash);

        }

    } else {

        // Print all matching names, then redraw the prompt and current input.

        io.print("\r\n");

        for (0..match_count) |j| {

            io.print(matches[j][0..match_lens[j]]);
            io.print("/  ");

        }

        io.print("\r\n");
        print_prompt();
        io.print(buf[0..pos.*]);

    }

}

fn starts_with(s: []const u8, prefix: []const u8) bool {

    if (prefix.len > s.len) return false;

    for (prefix, 0..) |ch, j| {
        if (s[j] != ch) return false;
    }

    return true;

}

// String helpers

/// Extract the first whitespace-delimited word from a string.
fn first_word(s: []const u8) []const u8 {

    var start: usize = 0;

    while (start < s.len and s[start] == ' ') start += 1;

    var end = start;

    while (end < s.len and s[end] != ' ') end += 1;

    return s[start..end];

}

/// Trim leading and trailing spaces.
fn trim(s: []const u8) []const u8 {

    var start: usize = 0;

    while (start < s.len and s[start] == ' ') start += 1;

    var end: usize = s.len;

    while (end > start and s[end - 1] == ' ') end -= 1;

    return s[start..end];

}

/// Compare two slices for equality.
fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
