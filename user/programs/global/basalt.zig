// user/basalt.zig - BASALT: Basic Adaptive Shell And Lightweight Terminal

const sys = @import("syscall");
const io = @import("io");

const MAX_LINE: usize = 256;
const MAX_PIPE_STAGES: usize = 8;
const MAX_ARGS: usize = 16;

export fn _start() noreturn {

    io.println("BASALT ......... Ready");
    io.println("Type 'help' for available commands, 'exit' to relaunch.\r\n");

    var line_buf: [MAX_LINE]u8 = undefined;

    while (true) {

        io.print("basalt> ");

        const line = read_line_echo(&line_buf);

        if (line.len == 0) continue;

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

        run_single(stages[0]);

    } else {

        run_pipeline(stages[0..stage_count]);

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

/// Read a line from stdin with character echo and backspace support.
fn read_line_echo(buf: []u8) []u8 {

    var pos: usize = 0;

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

        // Ignores non-printable characters.

        if (c < 0x20) continue;

        buf[pos] = c;
        pos += 1;

        // Echo the character.

        _ = sys.write(sys.STDOUT, @as(*const [1]u8, @ptrCast(&c)));

    }

    return buf[0..pos];

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
