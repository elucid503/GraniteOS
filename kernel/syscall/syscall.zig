// kernel/syscall/syscall.zig - Syscall dispatch (with custom GraniteOS syscall numbers)

const uart = @import("../drivers/uart.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table = @import("../memory/page_table.zig");
const process = @import("../process/process.zig");
const fs = @import("../fs/fs.zig");
const signal = @import("../signal/signal.zig");
const user_programs = @import("user_programs");

const SYS_WRITE: u64 = 1;
const SYS_READ: u64 = 2;
const SYS_EXIT: u64 = 3;
const SYS_GETPID: u64 = 4;
const SYS_FORK: u64 = 5;
const SYS_EXECVE: u64 = 6;
const SYS_BRK: u64 = 7;
const SYS_WAIT4: u64 = 8;
const SYS_OPEN: u64 = 9;
const SYS_CLOSE: u64 = 10;
const SYS_PIPE: u64 = 11;
const SYS_CREATE: u64 = 12;
const SYS_KILL: u64 = 13;
const SYS_SIGACTION: u64 = 14;
const SYS_SIGRETURN: u64 = 15;

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

    var sp = saved_sp;

    switch (frame.x8) {

        SYS_READ => sp = sys_read(saved_sp, frame),
        SYS_WRITE => frame.x0 = sys_write(frame),
        SYS_EXIT => sp = sys_exit(saved_sp),
        SYS_GETPID => frame.x0 = @as(u64, scheduler.current_process().pid),
        SYS_FORK => sp = sys_fork(saved_sp, frame),
        SYS_EXECVE => sp = sys_execve(saved_sp, frame),
        SYS_BRK => frame.x0 = sys_brk(frame),
        SYS_WAIT4 => sp = sys_wait4(saved_sp, frame),
        SYS_OPEN => frame.x0 = sys_open(frame),
        SYS_CLOSE => frame.x0 = sys_close(frame),
        SYS_PIPE => frame.x0 = sys_pipe(frame),
        SYS_CREATE => frame.x0 = sys_create(frame),
        SYS_KILL => frame.x0 = sys_kill(frame),
        SYS_SIGACTION => frame.x0 = sys_sigaction(frame),
        SYS_SIGRETURN => return signal.sigreturn(saved_sp),

        else => frame.x0 = @bitCast(@as(i64, -38)), // -ENOSYS

    }

    return signal.check_and_deliver(sp);

}

// read(fd, buf, count) → bytes read, or negative error.
// fd 0 reads from UART. fd >= 3 goes through the file system / pipe layer.
// Pipe reads may block if the pipe is empty and writers exist.
fn sys_read(saved_sp: usize, frame: *Frame) usize {

    // UART stdin
    if (frame.x0 == 0) {

        const buf: [*]u8 = @ptrFromInt(frame.x1);
        const count = frame.x2;
        var n: usize = 0;

        while (n < count) {

            const c = uart.getchar() orelse break;
            buf[n] = c;
            n += 1;

        }

        frame.x0 = n;
        return saved_sp;

    }

    // fd-based read

    const pcb = scheduler.current_process();
    const fd = frame.x0;

    if (fd < fs.FIRST_FD or fd - fs.FIRST_FD >= scheduler.MAX_OPEN_FILES) {

        frame.x0 = @bitCast(@as(i64, -9)); // EBADF
        return saved_sp;

    }

    const idx = fd - fs.FIRST_FD;
    const desc = &pcb.file_descriptors[idx];

    if (!desc.active or !desc.can_read) {

        frame.x0 = @bitCast(@as(i64, -9));
        return saved_sp;

    }

    const buf: [*]u8 = @ptrFromInt(frame.x1);
    const count = frame.x2;

    if (desc.kind == .pipe) {

        const result = fs.pipe_read(desc.entry, buf, count);

        if (result.block) {

            // Back up ELR to the svc instruction so the syscall restarts when woken.
            frame.elr -= 4;
            pcb.waiting_on_pipe = @intCast(desc.entry);
            return scheduler.block_current(saved_sp);

        }

        frame.x0 = result.bytes;
        return saved_sp;

    }

    // Regular file
    frame.x0 = fs.file_read(desc, buf, count);
    return saved_sp;

}

// write(fd, buf, count) → bytes written, or negative error.
// fd 1/2 write to UART. fd >= 3 goes through file system / pipe layer.
fn sys_write(frame: *Frame) u64 {

    // UART stdout/stderr
    if (frame.x0 == 1 or frame.x0 == 2) {

        const buf: [*]const u8 = @ptrFromInt(frame.x1);
        for (buf[0..frame.x2]) |c| uart.putchar(c);
        return frame.x2;

    }

    // fd-based write

    const pcb = scheduler.current_process();
    const fd = frame.x0;

    if (fd < fs.FIRST_FD or fd - fs.FIRST_FD >= scheduler.MAX_OPEN_FILES) {

        return @bitCast(@as(i64, -9));

    }

    const idx = fd - fs.FIRST_FD;
    const desc = &pcb.file_descriptors[idx];

    if (!desc.active or !desc.can_write) {

        return @bitCast(@as(i64, -9));

    }

    const buf: [*]const u8 = @ptrFromInt(frame.x1);
    const count = frame.x2;

    if (desc.kind == .pipe) {

        const n = fs.pipe_write(desc.entry, buf, count);
        scheduler.wake_pipe_waiters(desc.entry);
        return n;

    }

    return fs.file_write(desc, buf, count);

}

// exit(code) - close fds, mark zombie, switch to next.
fn sys_exit(saved_sp: usize) usize {

    fs.close_all(scheduler.current_process());
    return scheduler.exit_current(saved_sp);

}

// wait4(pid, ...) - block until target exits, then return its PID.
fn sys_wait4(saved_sp: usize, frame: *Frame) usize {

    const target_pid: u32 = @intCast(frame.x0);
    return scheduler.wait_on(saved_sp, target_pid);

}

// fork() → 0 in child, child_pid in parent.
fn sys_fork(saved_sp: usize, frame: *Frame) usize {

    const parent = scheduler.current_process();

    const child_l0 = page_table.clone(parent.page_table_root) catch {

        frame.x0 = @bitCast(@as(i64, -12)); // ENOMEM
        return saved_sp;

    };

    const child_pid = scheduler.fork_user_task(saved_sp, child_l0) orelse {

        page_table.free(child_l0);
        frame.x0 = @bitCast(@as(i64, -12));
        return saved_sp;

    };

    // Increment pipe reference counts for fds the child inherited.
    fs.on_fork(&scheduler.processes[child_pid]);

    frame.x0 = @intCast(child_pid);
    return saved_sp;

}

// execve(path, argv, envp) - replace current process image.
fn sys_execve(saved_sp: usize, frame: *Frame) usize {

    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const path_len = str_len(path_ptr);
    const name = path_ptr[0..path_len];

    const elf_bytes = find_program(name) orelse {

        frame.x0 = @bitCast(@as(i64, -2)); // ENOENT
        return saved_sp;

    };

    const result = process.exec_current(elf_bytes) orelse {

        return scheduler.exit_current(saved_sp);

    };

    const new_frame: *Frame = @ptrFromInt(saved_sp);
    @memset(@as([*]u8, @ptrFromInt(saved_sp))[0..@sizeOf(Frame)], 0);

    new_frame.elr    = result.entry_point;
    new_frame.spsr   = 0x0; // SPSR_EL0T
    new_frame.sp_el0 = result.stack_top;

    return saved_sp;

}

// brk(addr) → new break address.
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

            if (!page_table.map_page(pcb.page_table_root, va, pa)) {

                physical_allocator.free_page(pa);
                return @intCast(pcb.user_brk);

            }

        }

        asm volatile ("isb" ::: .{ .memory = true });

    }

    pcb.user_brk = requested;
    return @intCast(requested);

}

// create(name) → 0 or negative error.
fn sys_create(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const name = name_ptr[0..str_len(name_ptr)];

    if (!fs.create_file(name, scheduler.current_process().pid)) {
        return @bitCast(@as(i64, -28)); // ENOSPC
    }

    return 0;

}

// open(name, flags) → fd or negative error.
// flags: bit 0 = read, bit 1 = write.
fn sys_open(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const flags = frame.x1;
    const name = name_ptr[0..str_len(name_ptr)];

    const result = fs.open_file(
        scheduler.current_process(),
        name,
        (flags & 1) != 0,
        (flags & 2) != 0,
    );

    return @bitCast(@as(i64, result));

}

// close(fd) → 0 or negative error.
fn sys_close(frame: *Frame) u64 {

    const result = fs.close_fd(scheduler.current_process(), frame.x0);
    return @bitCast(@as(i64, result));

}

// pipe(fds_ptr) → 0 or negative error. Writes [read_fd, write_fd] to user buffer.
fn sys_pipe(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const result = fs.create_pipe(pcb) orelse return @bitCast(@as(i64, -24)); // EMFILE

    const fds_ptr: [*]usize = @ptrFromInt(frame.x0);
    fds_ptr[0] = result.read_fd;
    fds_ptr[1] = result.write_fd;

    return 0;

}

// kill(pid, signal) → 0 or negative error.
fn sys_kill(frame: *Frame) u64 {

    const target_pid: u32 = @intCast(frame.x0);
    const sig: u3 = @intCast(frame.x1 & 0x7);

    if (!signal.send(target_pid, sig)) return @bitCast(@as(i64, -3)); // ESRCH

    return 0;

}

// sigaction(signal, handler) → 0 or negative error.
fn sys_sigaction(frame: *Frame) u64 {

    const sig: u3 = @intCast(frame.x0 & 0x7);
    const handler = frame.x1;

    if (!signal.set_handler(sig, handler)) return @bitCast(@as(i64, -22)); // EINVAL

    return 0;

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
