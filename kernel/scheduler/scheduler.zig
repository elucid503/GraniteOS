// kernel/scheduler/scheduler.zig - Round-robin process scheduler with full PCB

const page_table = @import("../memory/page_table.zig");

pub const KERNEL_STACK_SIZE: usize = 8192;

const MAX_PROCESSES: usize = 16;
const FRAME_SIZE: usize = 272; // Must match boot/vectors.S
const ELR_OFFSET: usize = 248;
const SPSR_OFFSET: usize = 256;
const SP_EL0_OFFSET: usize = 264;

const SPSR_EL1H: u64 = 0x5; // EL1h, interrupts enabled
const SPSR_EL0T: u64 = 0x0; // EL0t, interrupts enabled

pub const ProcessState = enum { empty, ready, running, blocked, zombie };

pub const MAX_OPEN_FILES: usize = 12;
pub const SIGNAL_COUNT: usize = 4;

pub const FdKind = enum { none, file, pipe };

/// Per-process file descriptor entry (fds 3+ map here; 0-2 are always UART).
pub const FdEntry = struct {

    active: bool = false,
    kind: FdKind = .none,
    entry: u8 = 0, // index into global file table or pipe table
    offset: usize = 0, // read/write cursor (files only)
    can_read: bool = false,
    can_write: bool = false,

};

/// Process Control Block - everything needed to pause and resume a process.
pub const PCB = struct {

    pid: u32,
    state: ProcessState,

    /// Physical address of the L0 page table (loaded into TTBR0_EL1 on context switch).
    page_table_root: usize,

    /// Saved SP_EL1 when not running (points into kernel_stack).
    kernel_stack_pointer: usize,

    /// Current user heap break address; 0 for kernel tasks.
    user_brk: usize,

    /// PID this process is waiting on (valid when state == .blocked).
    wait_target_pid: u32,

    // File descriptors

    file_descriptors: [MAX_OPEN_FILES]FdEntry = [_]FdEntry{.{}} ** MAX_OPEN_FILES,

    /// Pipe index this process is blocked on (-1 = not waiting).
    waiting_on_pipe: i8 = -1,

    /// Pipe-based redirects for stdin/stdout (-1 = use UART).
    stdin_pipe: i8 = -1,
    stdout_pipe: i8 = -1,

    /// Current directory: logical root (`0xFF`) or a directory inode index in the ramfs table.
    fs_cwd: u8 = 0xFF,

    // Signal state

    pending_signals: u8 = 0,
    signal_handlers: [SIGNAL_COUNT]usize = [_]usize{0} ** SIGNAL_COUNT,
    signal_delivering: bool = false,
    stopped_by_signal: bool = false,

    /// Saved context for signal return (populated on signal delivery).
    saved_signal_elr: u64 = 0,
    saved_signal_sp: u64 = 0,
    saved_signal_x0: u64 = 0,
    saved_signal_x30: u64 = 0,

    /// Dedicated kernel stack for exception and syscall handling.
    kernel_stack: [KERNEL_STACK_SIZE]u8 align(16),

};

pub var processes: [MAX_PROCESSES]PCB = undefined;

pub var process_count: usize = 0;
var current_index: usize = 0;

pub fn init() void {

    for (&processes) |*p| p.state = .empty;

    // Process 0: idle task running on the boot stack and boot page table.

    processes[0] = .{

        .pid = 0,
        .state = .running,
        .page_table_root = page_table.boot_root(),
        .kernel_stack_pointer = 0,
        .user_brk = 0,
        .wait_target_pid = 0,
        .kernel_stack = undefined,

    };

    process_count = 1;
    current_index = 0;

}

/// Spawn a kernel-mode (EL1) task.
pub fn spawn_kernel_task(entry_point: *const fn () noreturn) void {

    const pid = find_free_slot() orelse return;
    const pcb = &processes[pid];

    pcb.* = .{

        .pid = @intCast(pid),
        .state = .ready,
        .page_table_root = page_table.boot_root(),
        .kernel_stack_pointer = 0,
        .user_brk = 0,
        .wait_target_pid = 0,
        .kernel_stack = undefined,

    };

    const initial_sp = kernel_stack_top(pcb) - FRAME_SIZE;

    build_initial_frame(initial_sp, @intFromPtr(entry_point), SPSR_EL1H, 0);
    pcb.kernel_stack_pointer = initial_sp;

}

/// Spawn a user-mode (EL0) task with a pre-built page table.
pub fn spawn_user_task(entry_point: usize, user_stack_top: usize, initial_brk: usize, l0_pa: usize) void {

    const pid = find_free_slot() orelse return;
    const pcb = &processes[pid];

    pcb.* = .{

        .pid = @intCast(pid),
        .state = .ready,
        .page_table_root = l0_pa,
        .kernel_stack_pointer = 0,
        .user_brk = initial_brk,
        .wait_target_pid = 0,
        .kernel_stack = undefined,

    };

    const initial_sp = kernel_stack_top(pcb) - FRAME_SIZE;

    build_initial_frame(initial_sp, entry_point, SPSR_EL0T, user_stack_top);
    pcb.kernel_stack_pointer = initial_sp;

}

/// Timer tick: save current SP, advance to next ready process, return its SP.
pub fn tick(saved_sp: usize) usize {

    if (processes[current_index].state == .running) {

        processes[current_index].kernel_stack_pointer = saved_sp;
        processes[current_index].state = .ready;

    }

    return advance_to_next();

}

/// Mark the current process zombie, wake any process waiting on this PID,
/// and switch to the next ready process. If a waiter exists, the zombie is
/// immediately reaped (marked empty) so the slot can be reused.
pub fn exit_current(saved_sp: usize) usize {

    const exiting_pid = processes[current_index].pid;
    const exiting = &processes[current_index];

    exiting.kernel_stack_pointer = saved_sp;
    exiting.state = .zombie;

    var reaped = false;

    for (&processes) |*proc| {

        if (proc.state == .blocked and proc.wait_target_pid == exiting_pid) {

            proc.state = .ready;

            const x0_ptr: *u64 = @ptrFromInt(proc.kernel_stack_pointer);
            x0_ptr.* = @intCast(exiting_pid);

            reaped = true;

        }

    }

    // If a waiter was found, the zombie is reaped immediately.
    if (reaped) exiting.state = .empty;

    return advance_to_next();

}

/// Block the current process until the target PID exits.
/// Returns immediately if the target is already zombie (and reaps it).
pub fn wait_on(saved_sp: usize, target_pid: u32) usize {

    if (target_pid >= process_count) return saved_sp;

    if (processes[target_pid].state == .zombie) {

        processes[target_pid].state = .empty; // Reap
        const x0_ptr: *u64 = @ptrFromInt(saved_sp);
        x0_ptr.* = @intCast(target_pid);
        return saved_sp;

    }

    // Block until target exits.

    processes[current_index].wait_target_pid = target_pid;
    return block_current(saved_sp);

}

/// Block the current process and switch to the next ready process.
pub fn block_current(saved_sp: usize) usize {

    processes[current_index].kernel_stack_pointer = saved_sp;
    processes[current_index].state = .blocked;
    return advance_to_next();

}

/// Wake all processes blocked on a pipe read for the given pipe index.
pub fn wake_pipe_waiters(pipe_index: u8) void {

    for (&processes) |*proc| {

        if (proc.state == .blocked and proc.waiting_on_pipe == @as(i8, @intCast(pipe_index))) {

            proc.state = .ready;
            proc.waiting_on_pipe = -1;

        }

    }

}

/// Return a pointer to the PCB for the given PID, or null if out of range.
pub fn get_process(pid: u32) ?*PCB {

    if (pid >= process_count) return null;
    return &processes[pid];

}

/// Return a pointer to the currently running PCB.
pub fn current_process() *PCB {

    return &processes[current_index];

}

/// Return true if the given PID exists and is in the zombie state.
pub fn is_zombie(pid: u32) bool {

    if (pid >= process_count) return false;
    return processes[pid].state == .zombie;

}

/// Clone the current process into a new PCB, copying its exception frame.
/// The caller supplies the child's page table root and the saved kernel SP
/// (which points to the exception frame to copy).
/// Returns the child PID, or null if no free slot is available.
pub fn fork_user_task(parent_frame_sp: usize, child_l0: usize) ?u32 {

    const pid = find_free_slot() orelse return null;
    const parent = &processes[current_index];
    const child  = &processes[pid];

    child.* = .{

        .pid                  = @intCast(pid),
        .state                = .ready,
        .page_table_root      = child_l0,
        .kernel_stack_pointer = 0,
        .user_brk             = parent.user_brk,
        .wait_target_pid      = 0,
        .file_descriptors     = parent.file_descriptors,
        .stdin_pipe           = parent.stdin_pipe,
        .stdout_pipe          = parent.stdout_pipe,
        .fs_cwd               = parent.fs_cwd,
        .signal_handlers      = parent.signal_handlers,
        .kernel_stack         = undefined,

    };

    // Place a copy of the parent's exception frame at the top of the child's kernel stack.

    const child_stack_top = @intFromPtr(&child.kernel_stack) + KERNEL_STACK_SIZE;
    const child_sp = child_stack_top - FRAME_SIZE;

    const parent_bytes: [*]const u8 = @ptrFromInt(parent_frame_sp);
    const child_bytes: [*]u8 = @ptrFromInt(child_sp);

    @memcpy(child_bytes[0..FRAME_SIZE], parent_bytes[0..FRAME_SIZE]);

    // x0 is the first field of the frame; fork() returns 0 to the child.
    @as(*u64, @ptrFromInt(child_sp)).* = 0;

    child.kernel_stack_pointer = child_sp;

    return @intCast(pid);

}

/// Finds a free (empty) process slot, reusing reaped slots before extending.
fn find_free_slot() ?usize {

    for (1..process_count) |i| {

        if (processes[i].state == .empty) return i;

    }

    if (process_count < MAX_PROCESSES) {

        const slot = process_count;
        process_count += 1;
        return slot;

    }

    return null;

}

fn kernel_stack_top(pcb: *PCB) usize {

    return @intFromPtr(&pcb.kernel_stack) + KERNEL_STACK_SIZE;

}

fn build_initial_frame(sp: usize, elr: usize, spsr: u64, sp_el0: usize) void {

    const frame: [*]u8 = @ptrFromInt(sp);
    @memset(frame[0..FRAME_SIZE], 0);

    @as(*u64, @ptrFromInt(sp + ELR_OFFSET)).* = elr;
    @as(*u64, @ptrFromInt(sp + SPSR_OFFSET)).* = spsr;
    @as(*u64, @ptrFromInt(sp + SP_EL0_OFFSET)).* = sp_el0;

}

fn advance_to_next() usize {

    var next = (current_index + 1) % process_count;
    var tries: usize = 0;

    while (tries < process_count) : (tries += 1) {

        if (processes[next].state == .ready) {

            current_index = next;

            processes[current_index].state = .running;
            page_table.switch_to(processes[current_index].page_table_root);

            return processes[current_index].kernel_stack_pointer;

        }

        next = (next + 1) % process_count;

    }

    // No ready process - idle on process 0.

    current_index = 0;
    processes[0].state = .running;

    page_table.switch_to(processes[0].page_table_root);

    return processes[0].kernel_stack_pointer;

}
