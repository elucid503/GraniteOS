// kernel/scheduler/scheduler.zig - Internal round-robin task scheduler (kernel-only)

const uart = @import("../drivers/uart.zig");

const STACK_SIZE  = 4096;
const MAX_TASKS   = 8;
const FRAME_SIZE  = 272; // Must match boot/vectors.S
const ELR_OFFSET  = 248;
const SPSR_OFFSET = 256;

const Task = struct {

    stack_pointer: usize,
    state: State,

    const State = enum { ready, running };

};

var tasks: [MAX_TASKS]Task = undefined;
pub var task_count: usize = 0;

var current_task: usize = 0;

var task_stacks: [MAX_TASKS - 1][STACK_SIZE]u8 align(16) = undefined;

pub fn init() void {

    // Task 0 is the idle task (kmain). It's already running on the boot
    // stack - its SP will be saved when the first timer IRQ fires.

    tasks[0] = .{ .stack_pointer = 0, .state = .running };
    task_count = 1;

    spawn(task_a);
    spawn(task_b);

}

/// Called from the IRQ handler on every timer tick. Saves the current task's SP and returns the next task's SP.
pub fn tick(saved_sp: usize) usize {

    tasks[current_task].stack_pointer = saved_sp;
    tasks[current_task].state = .ready;

    current_task = (current_task + 1) % task_count;

    tasks[current_task].state = .running;
    return tasks[current_task].stack_pointer;

}


fn spawn(entry_point: *const fn () noreturn) void {

    const task_id = task_count;
    const stack_top = @intFromPtr(&task_stacks[task_id - 1]) + STACK_SIZE;

    // Build an initial frame identical to what save_regs produces

    const initial_sp = stack_top - FRAME_SIZE;
    const frame: [*]u8 = @ptrFromInt(initial_sp);
    @memset(frame[0..FRAME_SIZE], 0);

    const elr: *u64 = @ptrFromInt(initial_sp + ELR_OFFSET);
    elr.* = @intFromPtr(entry_point);

    const spsr: *u64 = @ptrFromInt(initial_sp + SPSR_OFFSET);
    spsr.* = 0x5; // EL1h, interrupts enabled

    tasks[task_id] = .{ .stack_pointer = initial_sp, .state = .ready };
    task_count += 1;

}


fn task_a() noreturn {

    while (true) {

        uart.putchar('A');
        busy_wait();

    }

}

fn task_b() noreturn {

    while (true) {

        uart.putchar('B');
        busy_wait();

    }

}

fn busy_wait() void {

    var i: u32 = 0;

    while (i < 2_000_000) : (i += 1) {

        asm volatile ("");

    }

}
