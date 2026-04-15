// user/basalt.zig - BASALT: Basic Adaptive Shell And Lightweight Terminal

const sys = @import("syscall");
const io = @import("io");
const wm = @import("wm");

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

var h_nodes: [HISTORY_MAX]HistoryNode = undefined;
var h_head: usize = NONE;
var h_tail: usize = NONE;
var h_count: usize = 0;

// Split-pane state.

const MAX_PANES: usize = 2;
const SPLIT_COL: usize = 40; // column where the vertical divider sits (0-indexed)
// Pane 1 content starts 2 columns after the divider (divider + space).
// relay_paned uses col_start+1 (1-indexed), so SLAVE_COL+1 = SPLIT_COL+3 = col 43.
const SLAVE_COL: usize = SPLIT_COL + 2;
const MAX_CWD_DISP: usize = 10;

var split_mode: bool = false;
var active_pane: usize = 0;
var pane_cwd: [MAX_PANES][257]u8 = undefined;
var pane_cwd_len: [MAX_PANES]usize = .{0} ** MAX_PANES;
var pane_h_nodes: [HISTORY_MAX]HistoryNode = undefined; // saved history for pane 0
var pane_h_head: usize = NONE;
var pane_h_tail: usize = NONE;
var pane_h_count: usize = 0;

var pane_switched: bool = false;
var pane_new_requested: bool = false;
var pane_close_requested: bool = false;

// True when the split header (full separator + both prompts) should be redrawn.
// Set to true on every pane switch so each pane entry draws the header exactly once.
var needs_full_header: bool = true;

// Slave process state (valid when split_mode == true).

var pane1_write_fd: isize = -1; // write end of slave's stdin pipe
var pane1_read_fd: isize = -1;  // read end kept open to hold reader_count > 0
var pane1_pid: u32 = 0;

// Set to true when this process is running as the pane-1 slave shell.

var is_slave_mode: bool = false;

/// Push a command onto the front of the history list.
/// Evicts the oldest entry when full. Skips duplicate of the most recent entry.
fn history_push(cmd: []const u8) void {

    if (cmd.len == 0) return;

    if (h_head != NONE and str_eql(cmd, h_nodes[h_head].cmd[0..h_nodes[h_head].len])) return;

    var slot: usize = undefined;

    if (h_count < HISTORY_MAX) {

        slot = h_count;
        h_count += 1;

    } else {

        slot = h_tail;
        const new_tail = h_nodes[slot].prev;

        if (new_tail != NONE) h_nodes[new_tail].next = NONE;

        h_tail = new_tail;

    }

    const copy_len = if (cmd.len < MAX_LINE) cmd.len else MAX_LINE;

    @memcpy(h_nodes[slot].cmd[0..copy_len], cmd[0..copy_len]);

    h_nodes[slot].len = copy_len;
    h_nodes[slot].prev = NONE;
    h_nodes[slot].next = h_head;

    if (h_head != NONE) h_nodes[h_head].prev = slot;

    h_head = slot;

    if (h_tail == NONE) h_tail = slot;

}

// When called with "slave" as argv[1], this process becomes the pane-1 shell.
export fn _start(argc: usize, argv: [*]const ?[*:0]const u8) noreturn {

    if (argc >= 2 and argv[1] != null and cstr_eql(argv[1].?, "slave")) {

        is_slave_mode = true;
        run_slave();
        sys.exit(0);

    }

    io.println("BASALT ......... Ready\r\n");
    io.println("Type 'help' for available commands, 'exit' to relaunch.");
    io.println("Alt+N: new pane  Alt+S: switch pane  Alt+C: close pane\r\n");

    var line_buf: [MAX_LINE]u8 = undefined;

    while (true) {

        if (split_mode) {

            if (active_pane == 0) {

                run_split_iteration(&line_buf);

            } else {

                // Draw split header positioning cursor in pane 1, then proxy.
                print_split_prompt();
                proxy_pane1();

            }

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

// Slave shell: reads from pipe-based stdin, executes commands with column-aligned output.
// Does not print its own prompt (parent draws the split header and positions the cursor).
fn run_slave() noreturn {

    // Initialize the slave's wm module with the split layout so buf_divider_char(),
    // buf_separator(), and relay_paned() all draw the correct divider.
    wm.init_split(SPLIT_COL);

    var line_buf: [MAX_LINE]u8 = undefined;

    while (true) {

        // Parent draws the initial prompt via print_split_prompt on the header line.
        // After every subsequent command (or empty input) we draw our own prompt so
        // the user always sees a fresh "basalt [cwd]> " in the right pane column.

        const line = read_line_impl(&line_buf, .{ .max_width = MAX_LINE - 1, .split_tab = false });

        if (line.len > 0) {

            history_push(line);

            if (str_eql(line, "exit")) sys.exit(0);

            if (!try_builtin(line)) run_paned(line);

        }

        slave_print_prompt();

    }

}

// Run a command with stdout piped and relayed to pane 1's column.
// Falls back to run_single on pipe failure.
fn run_paned(cmd: []const u8) void {

    // Split by '|' to determine if it is a pipeline.

    var stages: [MAX_PIPE_STAGES][]const u8 = undefined;
    var stage_count: usize = 0;
    var start: usize = 0;

    for (cmd, 0..) |c, i| {

        if (c == '|') {

            if (stage_count >= MAX_PIPE_STAGES) {
                run_single(cmd);
                return;
            }

            stages[stage_count] = trim(cmd[start..i]);
            stage_count += 1;
            start = i + 1;

        }

    }

    stages[stage_count] = trim(cmd[start..]);
    stage_count += 1;

    for (stages[0..stage_count]) |s| {
        if (s.len == 0) { run_single(cmd); return; }
    }

    if (stage_count == 1) {

        run_single_paned(stages[0]);

    } else {

        run_pipeline_paned(stages[0..stage_count]);

    }

}

// Fork a child, pipe its stdout, relay output to pane 1's column.
fn run_single_paned(cmd: []const u8) void {

    var relay_pipe: [2]usize = undefined;

    if (sys.pipe(&relay_pipe) < 0) {
        run_single(cmd);
        return;
    }

    const child = sys.fork();

    if (child < 0) {

        _ = sys.close(relay_pipe[0]);
        _ = sys.close(relay_pipe[1]);
        io.println("basalt: fork failed");
        return;

    }

    if (child == 0) {

        _ = sys.dup2(relay_pipe[1], 1); // child stdout → relay pipe write end
        _ = sys.close(relay_pipe[0]);
        _ = sys.close(relay_pipe[1]);
        exec_cmd(cmd);

    }

    // Wait for the child to finish so all output is in the pipe buffer, THEN relay
    // it.  This avoids the race where relay_paned sees writer_count==0 (because the
    // parent closed the write end) before the child has written anything.
    _ = sys.waitpid(@intCast(child));
    _ = sys.close(relay_pipe[1]);
    wm.relay_paned(relay_pipe[0], SLAVE_COL);
    _ = sys.close(relay_pipe[0]);

}

// Run a pipeline with the final stage's stdout relayed to pane 1's column.
fn run_pipeline_paned(stages: []const []const u8) void {

    var pipe_fds: [MAX_PIPE_STAGES - 1][2]usize = undefined;
    var relay_pipe: [2]usize = undefined;
    var child_pids: [MAX_PIPE_STAGES]usize = undefined;

    if (sys.pipe(&relay_pipe) < 0) {
        run_pipeline(stages);
        return;
    }

    for (0..stages.len - 1) |i| {

        if (sys.pipe(&pipe_fds[i]) < 0) {

            _ = sys.close(relay_pipe[0]);
            _ = sys.close(relay_pipe[1]);

            for (0..i) |j| {
                _ = sys.close(pipe_fds[j][0]);
                _ = sys.close(pipe_fds[j][1]);
            }

            run_pipeline(stages);
            return;

        }

    }

    for (stages, 0..) |cmd, i| {

        const child = sys.fork();

        if (child < 0) {

            io.println("basalt: fork failed in pipeline");
            break;

        }

        if (child == 0) {

            if (i > 0) _ = sys.dup2(pipe_fds[i - 1][0], 0);

            if (i < stages.len - 1) {
                _ = sys.dup2(pipe_fds[i][1], 1);
            } else {
                // Last stage stdout → relay pipe.
                _ = sys.dup2(relay_pipe[1], 1);
            }

            for (0..stages.len - 1) |j| {
                _ = sys.close(pipe_fds[j][0]);
                _ = sys.close(pipe_fds[j][1]);
            }

            _ = sys.close(relay_pipe[0]);
            _ = sys.close(relay_pipe[1]);
            exec_cmd(cmd);

        }

        child_pids[i] = @intCast(child);

    }

    // Close the parent's copies of all inter-stage pipe ends so data flows naturally.
    for (0..stages.len - 1) |j| {
        _ = sys.close(pipe_fds[j][0]);
        _ = sys.close(pipe_fds[j][1]);
    }

    // Wait for all stages to finish so their output is fully buffered before we relay.
    for (0..stages.len) |i| {
        _ = sys.waitpid(child_pids[i]);
    }

    _ = sys.close(relay_pipe[1]);
    wm.relay_paned(relay_pipe[0], SLAVE_COL);
    _ = sys.close(relay_pipe[0]);

}

// One iteration of the split-pane loop for pane 0.
fn run_split_iteration(line_buf: *[MAX_LINE]u8) void {

    chdir_pane(0);

    // Draw the full separator+prompt header only on the first iteration after a pane
    // switch (or split entry).  Subsequent iterations use a plain inline prompt so the
    // header is not repeated after every command.

    if (needs_full_header) {
        print_split_prompt();
        needs_full_header = false;
    } else {
        print_pane0_prompt_only();
    }

    pane_switched = false;
    pane_close_requested = false;
    pane_new_requested = false;

    const max_w = split_input_width(0);
    const line = read_line_impl(line_buf, .{ .max_width = max_w, .split_tab = true });

    if (pane_new_requested) {

        pane_new_requested = false;
        return;

    }

    if (pane_switched) {

        save_pane_cwd(0);
        save_pane_history();
        active_pane = 1;
        needs_full_header = true; // pane 1 entry needs its header
        return;

    }

    if (pane_close_requested) {

        save_pane_cwd(0);
        close_split();
        return;

    }

    if (line.len == 0) return;

    history_push(line);

    if (str_eql(line, "exit")) {

        io.println("Exiting BASALT...");
        sys.exit(0);

    }

    execute_split_p0(line);

    save_pane_cwd(0);
    save_pane_history();

}

// Proxy UART input to the slave process while active_pane == 1.
// Returns when Alt+S or Alt+C is pressed.
fn proxy_pane1() void {

    while (true) {

        const c = io.read_char();

        if (c == 0x1B) {

            const c2 = io.read_char();

            // Alt+S: switch back to pane 0.

            if (c2 == 's') {

                io.print("\r\n");
                load_pane_history();
                chdir_pane(0);
                active_pane = 0;
                needs_full_header = true; // pane 0 re-entry needs its header
                return;

            }

            // Alt+C: close split.

            if (c2 == 'c') {

                io.print("\r\n");
                load_pane_history();
                chdir_pane(0);
                needs_full_header = true;
                close_split();
                return;

            }

            // Alt+N: ignore (already in split mode).

            if (c2 == 'n') continue;

            // Forward ESC sequences (arrow keys, etc.) to slave.

            if (pane1_write_fd >= 0) {

                const esc_seq: [2]u8 = .{ 0x1B, c2 };
                _ = sys.write(@intCast(pane1_write_fd), &esc_seq);

            }

            continue;

        }

        if (pane1_write_fd >= 0) {

            const byte: [1]u8 = .{c};
            _ = sys.write(@intCast(pane1_write_fd), &byte);

        }

    }

}

// Close the split, kill the slave stdin pipe, and reset to single-pane mode.
fn close_split() void {

    if (pane1_write_fd >= 0) {

        // Closing the write end gives the slave an EOF on its stdin pipe.

        _ = sys.close(@intCast(pane1_write_fd));
        pane1_write_fd = -1;

    }

    if (pane1_read_fd >= 0) {

        _ = sys.close(@intCast(pane1_read_fd));
        pane1_read_fd = -1;

    }

    split_mode = false;
    active_pane = 0;
    wm.init_single();
    io.println("Split closed.");

}

// Draw the split header: separator line + pane 0 prompt + divider + pane 1 prompt.
// Positions the cursor in the active pane's input area.
// Called at most once per pane switch (guarded by needs_full_header).
fn print_split_prompt() void {

    const d0 = get_display_cwd(0);
    const p0_len = 11 + d0.len; // "basalt [" + cwd + "]> "

    wm.buf_reset();
    wm.buf_separator(.top);

    // Pane 0 prompt.

    wm.buf_str("basalt [");
    wm.buf_str(d0);
    wm.buf_str("]> ");

    // Pad to the divider column.

    var col: usize = p0_len;

    while (col < SPLIT_COL) : (col += 1) wm.buf_char(' ');

    wm.buf_divider_char();
    wm.buf_char(' ');

    // Pane 1 prompt header (slave draws its own prompt after each command; this
    // header line shows the initial / context-switch prompt for pane 1).

    wm.buf_str("basalt [/]> ");

    // Position cursor in active pane.

    if (active_pane == 0) {

        wm.buf_str("\x1B[");
        wm.buf_int(p0_len + 1);
        wm.buf_char('G');

    }

    // For active_pane == 1 cursor is already past "basalt [/]> " in pane 1's area.

    wm.flush();

}

// Inline pane-0 prompt: middle separator + prompt on same line as │.
// Drawing the separator before every prompt gives a continuous-divider feel
// and naturally re-anchors the UI after a `clear` command.
fn print_pane0_prompt_only() void {

    const d = get_display_cwd(0);
    const p0_len = 11 + d.len; // "basalt [" + cwd + "]> "

    wm.buf_reset();
    wm.buf_separator(.middle); // ─────┼───── \r\n  (cursor now at col 1)

    // Pane 0 prompt text.
    wm.buf_str("basalt [");
    wm.buf_str(d);
    wm.buf_str("]> ");

    // Draw │ at the divider column so the prompt line matches the separator.
    wm.buf_str("\x1B[");
    wm.buf_int(SPLIT_COL + 1); // 1-indexed divider column = 41
    wm.buf_char('G');
    wm.buf_divider_char();

    // Return cursor to the end of the pane-0 prompt so read_line_impl echoes there.
    wm.buf_str("\x1B[");
    wm.buf_int(p0_len + 1);
    wm.buf_char('G');

    wm.flush();

}

// Slave pane prompt: middle separator + │ + "basalt [cwd]> " in the pane-1 column.
// The separator before each prompt re-anchors the UI after commands (including
// `clear`) and gives a continuous-divider feel matching pane 0.
fn slave_print_prompt() void {

    var cwd_buf: [256]u8 = undefined;
    const n = sys.getcwd(&cwd_buf);

    wm.buf_reset();
    wm.buf_str("\r\n"); // ensure we start on a fresh line
    wm.buf_separator(.middle); // ─────┼───── \r\n  (cursor now at col 1)

    // Draw │ at the divider column, then the prompt text.
    wm.buf_str("\x1B[");
    wm.buf_int(SPLIT_COL + 1); // 1-indexed divider column = 41
    wm.buf_char('G');
    wm.buf_divider_char();
    wm.buf_char(' ');

    // "basalt [cwd]> " starts at SLAVE_COL + 1 (1-indexed) = 43.
    wm.buf_str("basalt [");

    if (n > 1) {

        const cwd = cwd_buf[0..@as(usize, @intCast(n)) - 1];
        const disp = if (cwd.len <= MAX_CWD_DISP) cwd else cwd[cwd.len - MAX_CWD_DISP ..];
        wm.buf_str(disp);

    } else {

        wm.buf_str("/");

    }

    wm.buf_str("]> ");
    wm.flush();

}

// Maximum typeable characters for a pane.
fn split_input_width(p: usize) usize {

    const pi = wm.pane(p);

    if (p == 0) {

        const d = get_display_cwd(0);
        const prompt_len = 11 + d.len;
        const pane_cols = pi.width - 1;
        if (prompt_len >= pane_cols) return 2;
        return pane_cols - prompt_len;

    }

    // Pane 1: "basalt [/]> " = 12 chars; width minus divider + space (2 chars).
    const pane_cols: usize = pi.width - 2;
    if (12 >= pane_cols) return 2;
    return pane_cols - 12;

}

fn get_display_cwd(p: usize) []const u8 {

    const len = pane_cwd_len[p];

    if (len == 0) return "/";

    const cwd = pane_cwd[p][0..len];

    return if (len <= MAX_CWD_DISP) cwd else cwd[len - MAX_CWD_DISP ..];

}

fn save_pane_cwd(p: usize) void {

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);

    if (n > 0) {

        const len: usize = @as(usize, @intCast(n)) - 1;
        @memcpy(pane_cwd[p][0..len], buf[0..len]);
        pane_cwd_len[p] = len;

    }

}

fn chdir_pane(p: usize) void {

    pane_cwd[p][pane_cwd_len[p]] = 0;
    _ = sys.chdir(@ptrCast(&pane_cwd[p]));

}

// Save current pane 0 history into the pane history slot (for restore after pane 1 session).
fn save_pane_history() void {

    pane_h_nodes = h_nodes;
    pane_h_head = h_head;
    pane_h_tail = h_tail;
    pane_h_count = h_count;

}

fn load_pane_history() void {

    h_nodes = pane_h_nodes;
    h_head = pane_h_head;
    h_tail = pane_h_tail;
    h_count = pane_h_count;

}

// Activate split-pane mode: fork a real slave basalt process for pane 1.
fn enter_split_mode() void {

    var slave_stdin: [2]usize = undefined;

    if (sys.pipe(&slave_stdin) < 0) {

        io.println("basalt: cannot create pipe for slave");
        return;

    }

    const child = sys.fork();

    if (child < 0) {

        _ = sys.close(slave_stdin[0]);
        _ = sys.close(slave_stdin[1]);
        io.println("basalt: fork failed");
        return;

    }

    if (child == 0) {

        // Child: redirect stdin to pipe read end, then exec a fresh basalt slave.

        _ = sys.dup2(slave_stdin[0], 0);
        _ = sys.close(slave_stdin[0]);
        _ = sys.close(slave_stdin[1]);

        var slave_argv: [3]?[*:0]const u8 = .{ "basalt", "slave", null };
        _ = sys.execve("basalt", @ptrCast(&slave_argv));
        sys.exit(1);

    }

    // Parent: keep BOTH ends. The read end must stay open so the kernel's
    // pipe.reader_count stays > 0 — pipe_write returns 0 when reader_count == 0,
    // which would silently discard everything sent to the slave. The slave reads
    // via pcb.stdin_pipe (a direct index), which bypasses the fd table and is
    // therefore not counted in reader_count on its own.

    pane1_read_fd  = @intCast(slave_stdin[0]);
    pane1_write_fd = @intCast(slave_stdin[1]);
    pane1_pid = @intCast(child);

    // Snapshot current CWD and history for pane 0 restoration.

    var buf: [256]u8 = undefined;
    const n = sys.getcwd(&buf);
    var cwd_len: usize = 0;

    if (n > 1) {

        cwd_len = @as(usize, @intCast(n)) - 1;
        @memcpy(pane_cwd[0][0..cwd_len], buf[0..cwd_len]);

    } else {

        pane_cwd[0][0] = '/';
        cwd_len = 1;

    }

    pane_cwd_len[0] = cwd_len;
    pane_cwd_len[1] = 0; // slave CWD unknown from parent; show "/"

    save_pane_history();

    active_pane = 0;
    split_mode = true;
    needs_full_header = true;
    wm.init_split(SPLIT_COL);

    io.println("Split: Alt+S to switch  Alt+C to close");

}

/// Parses and executes a command line, handling pipes if present.
fn execute(line: []const u8) void {

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

    if (stage_count >= MAX_PIPE_STAGES) {
        io.println("basalt: too many pipe stages");
        return;
    }

    stages[stage_count] = trim(line[start..]);
    stage_count += 1;

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

/// Handles `cd`, `location`, `new`, and `clear` in-process (must not fork).
fn try_builtin(line: []const u8) bool {

    const t = trim(line);

    // In split/slave mode, intercept `clear` so we can redraw the split UI
    // instead of letting relay_pane0 pipe the raw escape sequences through
    // (which would clear the screen with no automatic recovery).
    if (str_eql(t, "clear")) {
        if (!split_mode and !is_slave_mode) return false; // single mode: run the binary
        wm.buf_reset();
        wm.buf_str("\x1B[2J\x1B[H");
        wm.flush();
        if (split_mode) needs_full_header = true; // force full header on next pane-0 prompt
        return true;
    }

    if (str_eql(t, "location")) {

        builtin_location();
        return true;

    }

    if (str_eql(t, "new")) {

        if (!is_slave_mode and !split_mode) enter_split_mode();
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

    if (r < 0) io.println("cd: no such directory or not a directory");

}

/// Run a single command in split-pane mode (pane 0), piping stdout through
/// relay_pane0 so every output line gets the vertical divider drawn at SPLIT_COL.
fn run_single_split_p0(cmd: []const u8) void {

    var relay_pipe: [2]usize = undefined;

    if (sys.pipe(&relay_pipe) < 0) {
        run_single(cmd); // fallback: no relay
        return;
    }

    const child = sys.fork();

    if (child < 0) {
        _ = sys.close(relay_pipe[0]);
        _ = sys.close(relay_pipe[1]);
        run_single(cmd);
        return;
    }

    if (child == 0) {
        _ = sys.dup2(relay_pipe[1], 1);
        _ = sys.close(relay_pipe[0]);
        _ = sys.close(relay_pipe[1]);
        exec_cmd(cmd);
    }

    _ = sys.waitpid(@intCast(child));
    _ = sys.close(relay_pipe[1]);
    wm.relay_pane0(relay_pipe[0]);
    _ = sys.close(relay_pipe[0]);

}

/// Like execute() but uses run_single_split_p0 for external single commands so
/// pane-0 output stays bounded by the divider.
fn execute_split_p0(line: []const u8) void {

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

    if (stage_count >= MAX_PIPE_STAGES) {
        io.println("basalt: too many pipe stages");
        return;
    }

    stages[stage_count] = trim(line[start..]);
    stage_count += 1;

    for (stages[0..stage_count]) |s| {

        if (s.len == 0) {
            io.println("basalt: empty command in pipeline");
            return;
        }

    }

    if (stage_count == 1) {

        if (try_builtin(stages[0])) return;

        run_single_split_p0(stages[0]);

    } else {

        // Pipelines fall back to normal execution for now.
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

    for (stages, 0..) |cmd, i| {

        const child = sys.fork();

        if (child < 0) {
            io.println("basalt: fork failed in pipeline");
            break;
        }

        if (child == 0) {

            if (i > 0) _ = sys.dup2(pipe_fds[i - 1][0], 0);

            if (i < stages.len - 1) _ = sys.dup2(pipe_fds[i][1], 1);

            for (0..stages.len - 1) |j| {
                _ = sys.close(pipe_fds[j][0]);
                _ = sys.close(pipe_fds[j][1]);
            }

            exec_cmd(cmd);

        }

        child_pids[i] = @intCast(child);

    }

    for (0..stages.len - 1) |j| {
        _ = sys.close(pipe_fds[j][0]);
        _ = sys.close(pipe_fds[j][1]);
    }

    for (0..stages.len) |i| {
        _ = sys.waitpid(child_pids[i]);
    }

}

/// Parse a command string into argv and exec. Called in the child after fork.
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

        while (i < cmd.len and args_buf[i] == ' ') i += 1;

        if (i >= cmd.len) break;

        const word_start = i;

        while (i < cmd.len and args_buf[i] != ' ') i += 1;

        args_buf[i] = 0;
        argv[argc] = @ptrCast(&args_buf[word_start]);
        argc += 1;

        if (i < cmd.len) i += 1;

    }

    if (argc == 0) sys.exit(0);

    _ = sys.execve(argv[0].?, &argv);

    io.print("basalt: unknown command: ");
    io.println(first_word(cmd));
    sys.exit(1);

}

// Line reading

fn erase_chars(n: usize) void {

    var i: usize = 0;
    while (i < n) : (i += 1) io.print("\x08 \x08");

}

fn replace_line(buf: []u8, pos: *usize, line_len: *usize, new_cmd: []const u8) void {

    var k = pos.*;
    while (k < line_len.*) : (k += 1) io.print("\x1B[C");

    erase_chars(line_len.*);

    const copy_len = if (new_cmd.len < buf.len) new_cmd.len else buf.len - 1;

    @memcpy(buf[0..copy_len], new_cmd[0..copy_len]);
    pos.* = copy_len;
    line_len.* = copy_len;

    io.print(buf[0..copy_len]);

}

const ReadConfig = struct {
    max_width: usize,
    split_tab: bool,
};

/// Read a line from stdin with full editing support.
/// In split mode (split_tab=true): Alt+S/Alt+C/Alt+N trigger pane control flags.
fn read_line_impl(buf: []u8, config: ReadConfig) []u8 {

    const effective_max = @min(config.max_width, buf.len - 1);
    var pos: usize = 0;
    var line_len: usize = 0;
    var nav_cursor: usize = NONE;
    var saved_buf: [MAX_LINE]u8 = undefined;
    var saved_len: usize = 0;

    while (true) {

        const c = io.read_char();

        if (c == '\r' or c == '\n') {

            io.print("\r\n");
            return buf[0..line_len];

        }

        if (c == 0x08 or c == 0x7F) {

            if (pos > 0) {

                pos -= 1;
                line_len -= 1;

                var k: usize = pos;
                while (k < line_len) : (k += 1) buf[k] = buf[k + 1];

                io.print("\x08");
                io.print(buf[pos..line_len]);
                io.print(" ");

                var back: usize = line_len - pos + 1;
                while (back > 0) : (back -= 1) io.print("\x08");

            }

            continue;

        }

        if (c == 0x1B) {

            const c2 = io.read_char();

            if (c2 == 'n') {

                io.print("\r\n");
                pane_new_requested = true;
                return buf[0..0];

            }

            if (c2 == 's' and config.split_tab) {

                io.print("\r\n");
                pane_switched = true;
                return buf[0..0];

            }

            if (c2 == 'c' and config.split_tab) {

                io.print("\r\n");
                pane_close_requested = true;
                return buf[0..0];

            }

            if (c2 == '[' or c2 == 'O') {

                const c3 = io.read_char();

                if (c3 == 'A') {

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
                    replace_line(buf, &pos, &line_len, src[0..@min(src.len, effective_max)]);

                } else if (c3 == 'B') {

                    if (nav_cursor == NONE) { continue; }

                    const newer = h_nodes[nav_cursor].prev;

                    if (newer == NONE) {

                        replace_line(buf, &pos, &line_len, saved_buf[0..saved_len]);
                        nav_cursor = NONE;

                    } else {

                        nav_cursor = newer;
                        const src = h_nodes[nav_cursor].cmd[0..h_nodes[nav_cursor].len];
                        replace_line(buf, &pos, &line_len, src[0..@min(src.len, effective_max)]);

                    }

                } else if (c3 == 'C') {

                    if (pos < line_len) {
                        pos += 1;
                        io.print("\x1B[C");
                    }

                } else if (c3 == 'D') {

                    if (pos > 0) {
                        pos -= 1;
                        io.print("\x1B[D");
                    }

                }

            }

            continue;

        }

        if (c == 0x09) {

            while (pos < line_len) : (pos += 1) io.print("\x1B[C");

            tab_complete(buf, &pos);
            line_len = pos;
            nav_cursor = NONE;
            continue;

        }

        if (c < 0x20) continue;

        nav_cursor = NONE;

        if (line_len >= effective_max) continue;

        var k: usize = line_len;
        while (k > pos) : (k -= 1) buf[k] = buf[k - 1];

        buf[pos] = c;
        line_len += 1;

        io.print(buf[pos..line_len]);
        pos += 1;

        var back: usize = line_len - pos;
        while (back > 0) : (back -= 1) io.print("\x08");

    }

}

// Tab completion

/// Complete the current partial word as a directory path.
fn tab_complete(buf: []u8, pos: *usize) void {

    var word_start = pos.*;

    while (word_start > 0 and buf[word_start - 1] != ' ') {
        word_start -= 1;
    }

    const word = buf[word_start..pos.*];

    var slash_pos: ?usize = null;

    for (word, 0..) |ch, i| {
        if (ch == '/') slash_pos = i;
    }

    const dir_part: []const u8 = if (slash_pos) |sp| word[0 .. sp + 1] else "";
    const prefix: []const u8 = if (slash_pos) |sp| word[sp + 1 ..] else word;

    var dir_buf: [MAX_LINE]u8 = undefined;
    var dir_path: ?[*:0]const u8 = null;

    if (dir_part.len > 0) {

        @memcpy(dir_buf[0..dir_part.len], dir_part);
        dir_buf[dir_part.len] = 0;
        dir_path = @ptrCast(&dir_buf);

    }

    var list_buf: [4096]u8 = undefined;
    const list_n = sys.listfiles_in(&list_buf, dir_path);

    const MAX_MATCHES = 16;
    const NAME_MAX = 32;

    var matches: [MAX_MATCHES][NAME_MAX]u8 = undefined;
    var match_lens: [MAX_MATCHES]usize = undefined;
    var match_count: usize = 0;

    var i: usize = 0;

    while (i < list_n and match_count < MAX_MATCHES) {

        const name_start = i;

        while (i < list_n and list_buf[i] != 0) i += 1;

        const name = list_buf[name_start..i];
        i += 1;

        const kind = if (i < list_n) list_buf[i] else 0;
        i += 1;
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

fn first_word(s: []const u8) []const u8 {

    var start: usize = 0;
    while (start < s.len and s[start] == ' ') start += 1;
    var end = start;
    while (end < s.len and s[end] != ' ') end += 1;
    return s[start..end];

}

fn trim(s: []const u8) []const u8 {

    var start: usize = 0;
    while (start < s.len and s[start] == ' ') start += 1;
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') end -= 1;
    return s[start..end];

}

fn str_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;

}

// Compare a null-terminated C string with a Zig string literal.
fn cstr_eql(s: [*:0]const u8, literal: []const u8) bool {

    var i: usize = 0;

    while (i < literal.len) : (i += 1) {
        if (s[i] != literal[i]) return false;
    }

    return s[literal.len] == 0;

}
