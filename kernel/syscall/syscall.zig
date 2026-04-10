// kernel/syscall/syscall.zig - Syscall dispatch (Linux AArch64 numbers)

const uart = @import("../drivers/uart.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table_mod = @import("../memory/page_table.zig");
const process = @import("../process/process.zig");
const user_programs = @import("user_programs");

const SYS_READ: u64 = 63;
const SYS_WRITE: u64 = 64;
const SYS_EXIT: u64 = 93;
const SYS_FORK: u64 = 57;
const SYS_GETPID: u64 = 172;
const SYS_EXECVE: u64 = 221;
const SYS_BRK: u64 = 214;

const PAGE_SIZE: usize = 4096;

// Mirrors the 272-byte exception frame from boot/vectors.S.
const Frame = extern struct {

    x0: u64, x1: u64, x2: u64, x3: u64,
    x4: u64, x5: u64, x6: u64, x7: u64,
    x8: u64, x9: u64, x10: u64, x11: u64,
    x12: u64, x13: u64, x14: u64, x15: u64,
    x16: u64, x17: u64, x18: u64, x19: u64,
    x20: u64, x21: u64, x22: u64, x23: u64,
    x24: u64, x25: u64, x26: u64, x27: u64,
    x28: u64, x29: u64, x30: u64,
    elr: u64,
    spsr: u64,
    sp_el0: u64,

};

/// Called from boot/vectors.S _el0_sync. Dispatches based on x8 (syscall number).
/// Returns the kernel SP to resume - unchanged normally, different only on exit/fork.
pub export fn handle_syscall(saved_sp: usize) usize {

    const frame: *Frame = @ptrFromInt(saved_sp);

    switch (frame.x8) {

        SYS_READ => frame.x0 = sys_read(frame),
        SYS_WRITE => frame.x0 = sys_write(frame),
        SYS_EXIT => return sys_exit(saved_sp),
        SYS_FORK => return sys_fork(saved_sp, frame),
        SYS_GETPID => frame.x0 = @as(u64, scheduler.current_process().pid),
        SYS_EXECVE => return sys_execve(saved_sp, frame),
        SYS_BRK => frame.x0 = sys_brk(frame),

        else => frame.x0 = @bitCast(@as(i64, -38)), // -ENOSYS

    }

    return saved_sp;

}

// read(fd, buf, count) → bytes read, or -1 on error.
// fd 0 (stdin): non-blocking read from UART RX FIFO.
fn sys_read(frame: *Frame) u64 {

    if (frame.x0 != 0) return @bitCast(@as(i64, -9)); // -EBADF

    const buf: [*]u8 = @ptrFromInt(frame.x1);
    const count = frame.x2;

    var n: usize = 0;

    while (n < count) {

        const c = uart.getchar() orelse break;

        buf[n] = c;
        n += 1;

    }

    return n;

}

// write(fd, buf, count) → bytes written, or -1 on error.
fn sys_write(frame: *Frame) u64 {

    if (frame.x0 != 1 and frame.x0 != 2) return @bitCast(@as(i64, -9)); // -EBADF

    const buf: [*]const u8 = @ptrFromInt(frame.x1);
    for (buf[0..frame.x2]) |c| uart.putchar(c);

    return frame.x2;

}

// exit(code) - mark current process zombie, switch to next.
fn sys_exit(saved_sp: usize) usize {

    return scheduler.exit_current(saved_sp);

}

// fork() → 0 in child, child_pid in parent.
// Deep-copies the parent's page table and user memory into a new PCB.
fn sys_fork(saved_sp: usize, frame: *Frame) usize {

    const parent = scheduler.current_process();

    const child_l0 = page_table_mod.clone(parent.page_table_root) catch {

        frame.x0 = @bitCast(@as(i64, -12)); // -ENOMEM
        return saved_sp;

    };

    const child_pid = scheduler.fork_user_task(saved_sp, child_l0) orelse {

        page_table_mod.free(child_l0);
        frame.x0 = @bitCast(@as(i64, -12));

        return saved_sp;

    };

    frame.x0 = @intCast(child_pid);

    return saved_sp;

}

// execve(path, argv, envp) - replace current process image with a named embedded binary.
// path is a null-terminated string matching a name in user_programs.
// argv and envp are ignored.
fn sys_execve(saved_sp: usize, frame: *Frame) usize {

    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const path_len = str_len(path_ptr);
    const name = path_ptr[0..path_len];

    // Find the named program in the embedded program list.
    const elf_bytes = find_program(name) orelse {

        frame.x0 = @bitCast(@as(i64, -2)); // -ENOENT
        return saved_sp;

    };

    const result = process.exec_current(elf_bytes) orelse {

        // Address space is trashed - kill the process and schedule the next one.
        return scheduler.exit_current(saved_sp);

    };

    // Rewrite the exception frame so eret enters the new program.

    const new_frame: *Frame = @ptrFromInt(saved_sp);
    @memset(@as([*]u8, @ptrFromInt(saved_sp))[0..@sizeOf(Frame)], 0);

    new_frame.elr    = result.entry_point;
    new_frame.spsr   = 0x0; // SPSR_EL0T
    new_frame.sp_el0 = result.stack_top;

    return saved_sp;

}

// brk(addr) → new break address.
// Maps new physical pages into the current process's page table as the heap grows.
fn sys_brk(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const requested: usize = @intCast(frame.x0);

    if (requested == 0) return @intCast(pcb.user_brk);

    if (requested > pcb.user_brk) {

        const first_new_page = align_up(pcb.user_brk, PAGE_SIZE);
        const last_new_page  = align_up(requested, PAGE_SIZE);

        var va = first_new_page;

        while (va < last_new_page) : (va += PAGE_SIZE) {

            const pa = physical_allocator.alloc_page() orelse return @intCast(pcb.user_brk);

            if (!page_table_mod.map_page(pcb.page_table_root, va, pa)) {

                physical_allocator.free_page(pa);
                return @intCast(pcb.user_brk);

            }

        }

        // ISB: ensure new mappings are visible before user code touches the new pages.
        asm volatile ("isb" ::: .{ .memory = true });

    }

    pcb.user_brk = requested;
    return @intCast(requested);

}

fn find_program(name: []const u8) ?[]const u8 {

    for (user_programs.programs) |prog| {

        if (std.mem.eql(u8, prog.name, name)) return prog.elf;

    }

    return null;

}

fn str_len(ptr: [*:0]const u8) usize {

    var i: usize = 0;
    while (ptr[i] != 0) i += 1;
    return i;

}

fn align_up(addr: usize, alignment: usize) usize {

    return (addr + alignment - 1) & ~(alignment - 1);

}

const std = @import("std");
