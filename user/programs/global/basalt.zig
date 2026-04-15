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

    io.println("BASALT ......... Ready");
    io.println("Type 'help' for available commands, 'exit' to relaunch.\r\n");

    var line_buf: [MAX_LINE]u8 = undefined;

    while (true) {

        print_prompt();

        const line = read_line_echo(&line_buf);

        if (line.len == 0) continue;

        history_push(line);

        // Built-in: exit

        if (str_eql(line, "exit")) {

            io.println("Exiting BASALT...");
            sys.exit(0);

        }

        execute(line);

    }

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

/// Handles `cd` and `path` in the shell process (must not fork).
fn try_builtin(line: []const u8) bool {

    const t = trim(line);

    if (str_eql(t, "location")) {

        builtin_location();
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

// Line reading with echo

/// Erase `n` characters from the terminal line by printing backspace-space-backspace sequences.
fn erase_chars(n: usize) void {

    var i: usize = 0;

    while (i < n) : (i += 1) {

        io.print("\x08 \x08");

    }

}

/// Replace the current terminal line (of length `pos`) with `new_cmd`, updating buf and pos.
fn replace_line(buf: []u8, pos: *usize, new_cmd: []const u8) void {

    erase_chars(pos.*);

    const copy_len = if (new_cmd.len < buf.len) new_cmd.len else buf.len - 1;

    @memcpy(buf[0..copy_len], new_cmd[0..copy_len]);
    pos.* = copy_len;

    io.print(buf[0..pos.*]);

}

/// Read a line from stdin with character echo, backspace, and arrow-key history navigation.
fn read_line_echo(buf: []u8) []u8 {

    var pos: usize = 0;

    // History navigation state (reset per prompt).

    var nav_cursor: usize = NONE; // NONE = at fresh prompt, else index into h_nodes
    var saved_buf: [MAX_LINE]u8 = undefined;
    var saved_len: usize = 0;

    while (pos < buf.len) {

        const c = io.read_char();

        // Enter

        if (c == '\r' or c == '\n') {

            io.print("\r\n");
            return buf[0..pos];

        }

        // Backspace / DEL

        if (c == 0x08 or c == 0x7F) {

            if (pos > 0) {

                pos -= 1;
                io.print("\x08 \x08");

            }

            continue;

        }

        // ESC: check for ANSI escape sequence (arrow keys).

        if (c == 0x1B) {

            const c2 = io.read_char();

            if (c2 == '[') {

                const c3 = io.read_char();

                if (c3 == 'A') {

                    // Up arrow: go to older history entry.

                    if (h_head == NONE) continue;

                    if (nav_cursor == NONE) {

                        // Save what the user was typing.

                        @memcpy(saved_buf[0..pos], buf[0..pos]);
                        saved_len = pos;
                        nav_cursor = h_head;

                    } else {

                        const older = h_nodes[nav_cursor].next;

                        if (older == NONE) continue; // already at oldest

                        nav_cursor = older;

                    }

                    replace_line(buf, &pos, h_nodes[nav_cursor].cmd[0..h_nodes[nav_cursor].len]);

                } else if (c3 == 'B') {

                    // Down arrow: go to newer history entry.

                    if (nav_cursor == NONE) continue;

                    const newer = h_nodes[nav_cursor].prev;

                    if (newer == NONE) {

                        // Back to the fresh line the user was typing.

                        replace_line(buf, &pos, saved_buf[0..saved_len]);
                        nav_cursor = NONE;

                    } else {

                        nav_cursor = newer;
                        replace_line(buf, &pos, h_nodes[nav_cursor].cmd[0..h_nodes[nav_cursor].len]);

                    }

                }

            }

            continue;

        }

        // Tab: attempt directory completion.

        if (c == 0x09) {

            tab_complete(buf, &pos);
            nav_cursor = NONE;
            continue;

        }

        // Ignores non-printable characters.

        if (c < 0x20) continue;

        // Reset nav on any regular input.

        nav_cursor = NONE;

        buf[pos] = c;
        pos += 1;

        // Echo the character.

        _ = sys.write(sys.STDOUT, @as(*const [1]u8, @ptrCast(&c)));

    }

    return buf[0..pos];

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

    var list_buf: [2048]u8 = undefined;
    const list_n = sys.listfiles_in(&list_buf, dir_path);

    // Collect directories whose names start with `prefix`.

    const MAX_MATCHES = 16;
    const NAME_MAX = 32;

    var matches: [MAX_MATCHES][NAME_MAX]u8 = undefined;
    var match_lens: [MAX_MATCHES]usize = undefined;
    var match_count: usize = 0;

    var i: usize = 0;

    while (i < list_n and match_count < MAX_MATCHES) {

        // Entry layout: name\0 kind_char\0 size_str\0

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
