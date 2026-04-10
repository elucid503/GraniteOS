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

    /// Dedicated kernel stack for exception and syscall handling.
    kernel_stack: [KERNEL_STACK_SIZE]u8 align(16),

};

var processes: [MAX_PROCESSES]PCB = undefined;

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
        .kernel_stack = undefined,

    };

    process_count = 1;
    current_index = 0;

}

/// Spawn a kernel-mode (EL1) task.
pub fn spawn_kernel_task(entry_point: *const fn () noreturn) void {

    const pid = process_count;
    const pcb = &processes[pid];

    pcb.* = .{

        .pid = @intCast(pid),
        .state = .ready,
        .page_table_root = page_table.boot_root(),
        .kernel_stack_pointer = 0,
        .user_brk = 0,
        .kernel_stack = undefined,

    };

    const initial_sp = kernel_stack_top(pcb) - FRAME_SIZE;

    build_initial_frame(initial_sp, @intFromPtr(entry_point), SPSR_EL1H, 0);
    pcb.kernel_stack_pointer = initial_sp;

    process_count += 1;

}

/// Spawn a user-mode (EL0) task with a pre-built page table.
pub fn spawn_user_task(entry_point: usize, user_stack_top: usize, initial_brk: usize, l0_pa: usize) void {

    const pid = process_count;
    const pcb = &processes[pid];

    pcb.* = .{

        .pid = @intCast(pid),
        .state = .ready,
        .page_table_root = l0_pa,
        .kernel_stack_pointer = 0,
        .user_brk = initial_brk,
        .kernel_stack = undefined,

    };

    const initial_sp = kernel_stack_top(pcb) - FRAME_SIZE;

    build_initial_frame(initial_sp, entry_point, SPSR_EL0T, user_stack_top);
    pcb.kernel_stack_pointer = initial_sp;

    process_count += 1;

}

/// Timer tick: save current SP, advance to next ready process, return its SP.
pub fn tick(saved_sp: usize) usize {

    if (processes[current_index].state == .running) {

        processes[current_index].kernel_stack_pointer = saved_sp;
        processes[current_index].state = .ready;

    }

    return advance_to_next();

}

/// Mark the current process zombie and switch to the next ready process.
pub fn exit_current(saved_sp: usize) usize {

    processes[current_index].kernel_stack_pointer = saved_sp;
    processes[current_index].state = .zombie;

    return advance_to_next();

}

/// Return a pointer to the currently running PCB.
pub fn current_process() *PCB {

    return &processes[current_index];

}

/// Clone the current process into a new PCB, copying its exception frame.
/// The caller supplies the child's page table root and the saved kernel SP
/// (which points to the exception frame to copy).
/// Returns the child PID, or null if MAX_PROCESSES is reached.
pub fn fork_user_task(parent_frame_sp: usize, child_l0: usize) ?u32 {

    if (process_count >= MAX_PROCESSES) return null;

    const pid = process_count;
    const parent = &processes[current_index];
    const child  = &processes[pid];

    child.* = .{

        .pid                  = @intCast(pid),
        .state                = .ready,
        .page_table_root      = child_l0,
        .kernel_stack_pointer = 0,
        .user_brk             = parent.user_brk,
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
    process_count += 1;

    return @intCast(pid);

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
