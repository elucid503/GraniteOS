// kernel/scheduler/scheduler.zig - SMP-aware round-robin process scheduler

const page_table = @import("../memory/page_table.zig");
const mutex = @import("../sync/mutex.zig");

pub const KERNEL_STACK_SIZE: usize = 8192;

pub const MAX_PROCESSES: usize = 16;
pub const MAX_CORES: usize = 4;

const FRAME_SIZE: usize = 272; // must match boot/vectors.S
const ELR_OFFSET: usize = 248;
const SPSR_OFFSET: usize = 256;
const SP_EL0_OFFSET: usize = 264;

const SPSR_EL1H: u64 = 0x5; // EL1h, interrupts enabled
const SPSR_EL0T: u64 = 0x0; // EL0t, interrupts enabled

const IDLE: usize = 0xFFFF; // sentinel: core has no user process scheduled

pub const ProcessState = enum { empty, ready, running, blocked, zombie };

pub const MAX_OPEN_FILES: usize = 12;
pub const SIGNAL_COUNT: usize = 4;

pub const FdKind = enum { none, file, pipe };

pub const FdEntry = struct {

    active: bool = false,
    kind: FdKind = .none,
    entry: u8 = 0, // index into file table or pipe table
    offset: usize = 0, // read/write cursor (files only)
    can_read: bool = false,
    can_write: bool = false,

};

/// Process Control Block: everything needed to pause and resume a process.
pub const PCB = struct {

    pid: u32,
    state: ProcessState,

    page_table_root: usize, // physical address of L0 page table, loaded into TTBR0_EL1 on context switch
    kernel_stack_pointer: usize, // saved SP_EL1 when not running (points into kernel_stack)
    user_brk: usize, // current user heap break; 0 for kernel tasks
    wait_target_pid: u32, // PID this process is blocked waiting on

    // File descriptors

    file_descriptors: [MAX_OPEN_FILES]FdEntry = [_]FdEntry{.{}} ** MAX_OPEN_FILES,

    waiting_on_pipe: i8 = -1, // pipe index this process is blocked on (-1 = not waiting)
    stdin_pipe: i8 = -1, // pipe redirect for stdin (-1 = use UART)
    stdout_pipe: i8 = -1, // pipe redirect for stdout (-1 = use UART)
    fs_cwd: u8 = 0xFF, // current directory: ROOT_DIR (0xFF) or a directory inode index

    // Signal state

    pending_signals: u8 = 0,
    signal_handlers: [SIGNAL_COUNT]usize = [_]usize{0} ** SIGNAL_COUNT,
    signal_delivering: bool = false,
    stopped_by_signal: bool = false,

    saved_signal_elr: u64 = 0, // saved context for signal return, populated on signal delivery
    saved_signal_sp: u64 = 0,
    saved_signal_x0: u64 = 0,
    saved_signal_x30: u64 = 0,

    kernel_stack: [KERNEL_STACK_SIZE]u8 align(16),

};

pub var processes: [MAX_PROCESSES]PCB = undefined;
pub var process_count: usize = 0;

var current_indices: [MAX_CORES]usize = [_]usize{IDLE} ** MAX_CORES; // per-core current process index
var idle_saved_sp: [MAX_CORES]usize = [_]usize{0} ** MAX_CORES; // per-core saved idle stack pointer

pub var core_count: usize = 1;

var sched_lock: mutex.Mutex = .{};

/// Returns the current core ID from MPIDR_EL1.Aff0.
pub fn get_core_id() usize {

    return asm volatile ("mrs %[out], mpidr_el1"
        : [out] "=r" (-> usize),
    ) & 0xFF;

}

pub fn init() void {

    for (&processes) |*p| p.state = .empty;

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
    current_indices[0] = 0;

}

/// Registers a secondary core as active. Called from kmain_secondary.
pub fn register_core(core_id: usize) void {

    if (core_id > 0 and core_id < MAX_CORES) {

        current_indices[core_id] = IDLE;

        sched_lock.lock();
        if (core_id + 1 > core_count) core_count = core_id + 1;
        sched_lock.unlock();

    }

}

/// Spawns a kernel-mode (EL1) task.
pub fn spawn_kernel_task(entry_point: *const fn () noreturn) void {

    sched_lock.lock();
    defer sched_lock.unlock();

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

/// Spawns a user-mode (EL0) task with a pre-built page table.
pub fn spawn_user_task(entry_point: usize, user_stack_top: usize, initial_brk: usize, l0_pa: usize) void {

    sched_lock.lock();
    defer sched_lock.unlock();

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

/// Saves the current SP, advances to the next ready process, and returns its SP.
pub fn tick(saved_sp: usize) usize {

    const core = get_core_id();

    sched_lock.lock();
    defer sched_lock.unlock();

    const idx = current_indices[core];

    if (idx == IDLE) {

        idle_saved_sp[core] = saved_sp;

    } else if (idx < MAX_PROCESSES and processes[idx].state == .running) {

        processes[idx].kernel_stack_pointer = saved_sp;
        processes[idx].state = .ready;

    }

    return advance_for_core(core);

}

/// Marks the current process zombie, wakes any waiter, and switches to the next ready process.
pub fn exit_current(saved_sp: usize) usize {

    const core = get_core_id();

    sched_lock.lock();
    defer sched_lock.unlock();

    const idx = current_indices[core];
    if (idx == IDLE or idx >= MAX_PROCESSES) return go_idle(core);

    const exiting_pid = processes[idx].pid;
    const exiting = &processes[idx];

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

    if (reaped) exiting.state = .empty; // reap immediately if a waiter was found

    return advance_for_core(core);

}

/// Blocks the current process until target_pid exits. Returns immediately if the target is already zombie.
pub fn wait_on(saved_sp: usize, target_pid: u32) usize {

    const core = get_core_id();

    sched_lock.lock();
    defer sched_lock.unlock();

    if (target_pid >= process_count) return saved_sp;

    if (processes[target_pid].state == .zombie) {

        processes[target_pid].state = .empty;
        const x0_ptr: *u64 = @ptrFromInt(saved_sp);
        x0_ptr.* = @intCast(target_pid);
        return saved_sp;

    }

    const idx = current_indices[core];
    if (idx == IDLE or idx >= MAX_PROCESSES) return saved_sp;

    processes[idx].wait_target_pid = target_pid;
    processes[idx].kernel_stack_pointer = saved_sp;
    processes[idx].state = .blocked;

    return advance_for_core(core);

}

/// Blocks the current process and switches to the next ready process.
pub fn block_current(saved_sp: usize) usize {

    const core = get_core_id();

    sched_lock.lock();
    defer sched_lock.unlock();

    const idx = current_indices[core];
    if (idx == IDLE or idx >= MAX_PROCESSES) return saved_sp;

    processes[idx].kernel_stack_pointer = saved_sp;
    processes[idx].state = .blocked;

    return advance_for_core(core);

}

/// Wakes all processes blocked on a pipe read for the given pipe index.
pub fn wake_pipe_waiters(pipe_index: u8) void {

    sched_lock.lock();
    defer sched_lock.unlock();

    for (&processes) |*proc| {

        if (proc.state == .blocked and proc.waiting_on_pipe == @as(i8, @intCast(pipe_index))) {

            proc.state = .ready;
            proc.waiting_on_pipe = -1;

        }

    }

}

/// Returns a pointer to the PCB for the given PID, or null if out of range.
pub fn get_process(pid: u32) ?*PCB {

    if (pid >= process_count) return null;
    return &processes[pid];

}

/// Returns a pointer to the currently running PCB on this core.
pub fn current_process() *PCB {

    const core = get_core_id();
    const idx = current_indices[core];

    if (idx == IDLE or idx >= MAX_PROCESSES) return &processes[0]; // idle falls back to process 0

    return &processes[idx];

}

/// Returns true if the given PID is in the zombie state.
pub fn is_zombie(pid: u32) bool {

    if (pid >= process_count) return false;
    return processes[pid].state == .zombie;

}

/// Clones the current process into a new PCB, copying the exception frame. Returns the child PID, or null if no free slot.
pub fn fork_user_task(parent_frame_sp: usize, child_l0: usize) ?u32 {

    const core = get_core_id();

    sched_lock.lock();
    defer sched_lock.unlock();

    const pid = find_free_slot() orelse return null;
    const parent_idx = current_indices[core];
    if (parent_idx == IDLE or parent_idx >= MAX_PROCESSES) return null;

    const parent = &processes[parent_idx];
    const child = &processes[pid];

    child.* = .{

        .pid = @intCast(pid),
        .state = .ready,
        .page_table_root = child_l0,
        .kernel_stack_pointer = 0,
        .user_brk = parent.user_brk,
        .wait_target_pid = 0,
        .file_descriptors = parent.file_descriptors,
        .stdin_pipe = parent.stdin_pipe,
        .stdout_pipe = parent.stdout_pipe,
        .fs_cwd = parent.fs_cwd,
        .signal_handlers = parent.signal_handlers,
        .kernel_stack = undefined,

    };

    // Copy parent's exception frame to the child's kernel stack; x0 = 0 (fork returns 0 in child)
    const child_stack_top = @intFromPtr(&child.kernel_stack) + KERNEL_STACK_SIZE;
    const child_sp = child_stack_top - FRAME_SIZE;

    const parent_bytes: [*]const u8 = @ptrFromInt(parent_frame_sp);
    const child_bytes: [*]u8 = @ptrFromInt(child_sp);

    @memcpy(child_bytes[0..FRAME_SIZE], parent_bytes[0..FRAME_SIZE]);

    @as(*u64, @ptrFromInt(child_sp)).* = 0;

    child.kernel_stack_pointer = child_sp;

    return @intCast(pid);

}

// Finds a free (empty) process slot, reusing reaped slots before extending. Caller must hold sched_lock.
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

// Selects the next ready user process for this core (skips index 0 = idle task). Caller must hold sched_lock.
fn advance_for_core(core: usize) usize {

    var start: usize = 1;
    var tries: usize = 0;

    while (tries < process_count) : (tries += 1) {

        const next = if (start < process_count) start else 1;
        if (next == 0) {
            start = 1;
            continue;
        }

        if (next < process_count and processes[next].state == .ready) {

            current_indices[core] = next;
            processes[next].state = .running;
            page_table.switch_to(processes[next].page_table_root);

            return processes[next].kernel_stack_pointer;

        }

        start = next + 1;

    }

    return go_idle(core);

}

fn go_idle(core: usize) usize {

    current_indices[core] = IDLE;
    page_table.switch_to(page_table.boot_root());

    if (core == 0) {

        current_indices[0] = 0;
        processes[0].state = .running;
        return idle_saved_sp[0];

    }

    return idle_saved_sp[core];

}
