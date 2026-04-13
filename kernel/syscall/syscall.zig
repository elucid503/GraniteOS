// kernel/syscall/syscall.zig - Syscall dispatch (with custom GraniteOS syscall numbers)

const uart = @import("../drivers/uart.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table = @import("../memory/page_table.zig");
const process = @import("../process/process.zig");
const fs = @import("../fs/fs.zig");
const signal = @import("../signal/signal.zig");
const user_programs = @import("user_programs");
const heap = @import("../memory/heap.zig");
const registry = @import("../registry.zig");

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
const SYS_DUP2: u64 = 16;
const SYS_LISTPROGS: u64 = 17;
const SYS_DELETE: u64 = 18;
const SYS_RENAME: u64 = 19;
const SYS_LISTFILES: u64 = 20;
const SYS_SYSINFO: u64 = 21;
const SYS_CHMOD: u64 = 22;
const SYS_CHDIR: u64 = 23;
const SYS_MKDIR: u64 = 24;
const SYS_RMDIR: u64 = 25;
const SYS_GETCWD: u64 = 26;

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
        SYS_DUP2 => frame.x0 = sys_dup2(frame),
        SYS_LISTPROGS => frame.x0 = sys_listprogs(frame),
        SYS_DELETE => frame.x0 = sys_delete(frame),
        SYS_RENAME => frame.x0 = sys_rename(frame),
        SYS_LISTFILES => frame.x0 = sys_listfiles(frame),
        SYS_SYSINFO => frame.x0 = sys_sysinfo(frame),
        SYS_CHMOD => frame.x0 = sys_chmod(frame),
        SYS_CHDIR => frame.x0 = sys_chdir(frame),
        SYS_MKDIR => frame.x0 = sys_mkdir(frame),
        SYS_RMDIR => frame.x0 = sys_rmdir(frame),
        SYS_GETCWD => frame.x0 = sys_getcwd(frame),

        else => frame.x0 = @bitCast(@as(i64, -38)), // -ENOSYS

    }

    return signal.check_and_deliver(sp);

}

// read(fd, buf, count) -> bytes read, or negative error.
// fd 0 reads from UART (or redirected pipe). fd >= 3 goes through the file system / pipe layer.
// Pipe reads may block if the pipe is empty and writers exist.
fn sys_read(saved_sp: usize, frame: *Frame) usize {

    // stdin: use pipe redirect if set, otherwise UART
    if (frame.x0 == 0) {

        const pcb = scheduler.current_process();

        if (pcb.stdin_pipe >= 0) {

            const pipe_idx: u8 = @intCast(pcb.stdin_pipe);
            const buf: [*]u8 = @ptrFromInt(frame.x1);
            const result = fs.pipe_read(pipe_idx, buf, frame.x2);

            if (result.block) {

                frame.elr -= 4;
                pcb.waiting_on_pipe = @intCast(pipe_idx);
                return scheduler.block_current(saved_sp);

            }

            frame.x0 = result.bytes;
            return saved_sp;

        }

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

// write(fd, buf, count) -> bytes written, or negative error.
// fd 1/2 write to UART (or redirected pipe). fd >= 3 goes through file system / pipe layer.
fn sys_write(frame: *Frame) u64 {

    // stdout: use pipe redirect if set, otherwise UART
    if (frame.x0 == 1) {

        const pcb = scheduler.current_process();

        if (pcb.stdout_pipe >= 0) {

            const pipe_idx: u8 = @intCast(pcb.stdout_pipe);
            const buf: [*]const u8 = @ptrFromInt(frame.x1);
            const n = fs.pipe_write(pipe_idx, buf, frame.x2);
            scheduler.wake_pipe_waiters(pipe_idx);
            return n;

        }

        const buf: [*]const u8 = @ptrFromInt(frame.x1);
        for (buf[0..frame.x2]) |c| uart.putchar(c);
        return frame.x2;

    }

    // stderr always goes to UART
    if (frame.x0 == 2) {

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

// fork() -> 0 in child, child_pid in parent.
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
// Copies argv strings into kernel memory before exec replaces the address space,
// then places them on the new user stack. Sets x0=argc, x1=argv pointer.
fn sys_execve(saved_sp: usize, frame: *Frame) usize {

    const MAX_ARGC = 16;
    const MAX_ARGV_TOTAL = 512;

    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const path_len = str_len(path_ptr);
    const name = path_ptr[0..path_len];

    // Copy argv strings into kernel-local storage before exec frees user memory.

    var argv_buf: [MAX_ARGV_TOTAL]u8 = undefined;
    var argv_offsets: [MAX_ARGC]usize = undefined;
    var argv_lens: [MAX_ARGC]usize = undefined;
    var argc: usize = 0;
    var argv_total: usize = 0;

    if (frame.x1 != 0) {

        const argv_ptrs: [*]const usize = @ptrFromInt(frame.x1);

        while (argc < MAX_ARGC) {

            const ptr_val = argv_ptrs[argc];
            if (ptr_val == 0) break;

            const arg_ptr: [*:0]const u8 = @ptrFromInt(ptr_val);
            const arg_len = str_len(arg_ptr);

            if (argv_total + arg_len + 1 > MAX_ARGV_TOTAL) break;

            argv_offsets[argc] = argv_total;
            argv_lens[argc] = arg_len;
            @memcpy(argv_buf[argv_total..][0..arg_len], arg_ptr[0..arg_len]);
            argv_buf[argv_total + arg_len] = 0;
            argv_total += arg_len + 1;
            argc += 1;

        }

    }

    const elf_bytes = resolve_exec_elf(name) orelse {

        frame.x0 = @bitCast(@as(i64, -2)); // ENOENT
        return saved_sp;

    };

    const result = process.exec_current(elf_bytes) orelse {

        return scheduler.exit_current(saved_sp);

    };

    // Place argv on the new user stack: strings first, then pointer array.

    var sp = result.stack_top;

    if (argc > 0) {

        // Write argument strings.
        sp -= argv_total;
        const str_base = sp;
        const dst: [*]u8 = @ptrFromInt(str_base);
        @memcpy(dst[0..argv_total], argv_buf[0..argv_total]);

        // Build argv pointer array (argc entries + null sentinel).
        const array_size = (argc + 1) * @sizeOf(usize);
        sp -= array_size;
        sp &= ~@as(usize, 15); // 16-byte align

        const argv_base: [*]usize = @ptrFromInt(sp);

        for (0..argc) |i| {
            argv_base[i] = str_base + argv_offsets[i];
        }

        argv_base[argc] = 0;

    }

    const new_frame: *Frame = @ptrFromInt(saved_sp);
    @memset(@as([*]u8, @ptrFromInt(saved_sp))[0..@sizeOf(Frame)], 0);

    new_frame.elr    = result.entry_point;
    new_frame.spsr   = 0x0; // SPSR_EL0T
    new_frame.sp_el0 = sp & ~@as(u64, 15);
    new_frame.x0     = argc;
    new_frame.x1     = if (argc > 0) sp else 0;

    return saved_sp;

}

// brk(addr) -> new break address.
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

// create(name) -> 0 or negative error.
fn sys_create(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const name = name_ptr[0..str_len(name_ptr)];

    const pcb = scheduler.current_process();

    if (!fs.create_file_path(pcb.fs_cwd, name, pcb.pid)) {
        return @bitCast(@as(i64, -28)); // ENOSPC
    }

    return 0;

}

// open(name, flags) -> fd or negative error.
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

// close(fd) -> 0 or negative error.
fn sys_close(frame: *Frame) u64 {

    const result = fs.close_fd(scheduler.current_process(), frame.x0);
    return @bitCast(@as(i64, result));

}

// pipe(fds_ptr) -> 0 or negative error. Writes [read_fd, write_fd] to user buffer.
fn sys_pipe(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const result = fs.create_pipe(pcb) orelse return @bitCast(@as(i64, -24)); // EMFILE

    const fds_ptr: [*]usize = @ptrFromInt(frame.x0);
    fds_ptr[0] = result.read_fd;
    fds_ptr[1] = result.write_fd;

    return 0;

}

// kill(pid, signal) -> 0 or negative error.
fn sys_kill(frame: *Frame) u64 {

    const target_pid: u32 = @intCast(frame.x0);
    const sig: u3 = @intCast(frame.x1 & 0x7);

    if (!signal.send(target_pid, sig)) return @bitCast(@as(i64, -3)); // ESRCH

    return 0;

}

// sigaction(signal, handler) -> 0 or negative error.
fn sys_sigaction(frame: *Frame) u64 {

    const sig: u3 = @intCast(frame.x0 & 0x7);
    const handler = frame.x1;

    if (!signal.set_handler(sig, handler)) return @bitCast(@as(i64, -22)); // EINVAL

    return 0;

}

// dup2(old_fd, new_fd) - redirect stdin (0) or stdout (1) to a pipe fd.
fn sys_dup2(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const old_fd = frame.x0;
    const new_fd = frame.x1;

    // Validate old_fd points to an active pipe descriptor.

    if (old_fd < fs.FIRST_FD or old_fd - fs.FIRST_FD >= scheduler.MAX_OPEN_FILES) {
        return @bitCast(@as(i64, -9)); // EBADF
    }

    const idx = old_fd - fs.FIRST_FD;
    const desc = &pcb.file_descriptors[idx];

    if (!desc.active or desc.kind != .pipe) {
        return @bitCast(@as(i64, -9));
    }

    if (new_fd == 0 and desc.can_read) {

        pcb.stdin_pipe = @intCast(desc.entry);
        return 0;

    }

    if (new_fd == 1 and desc.can_write) {

        pcb.stdout_pipe = @intCast(desc.entry);
        return 0;

    }

    return @bitCast(@as(i64, -22)); // EINVAL

}

// listprogs(buf, size) -> bytes written.
// Writes listed programs as category\0name\0description\0 triplets into buf.
fn sys_listprogs(frame: *Frame) u64 {

    const buf: [*]u8 = @ptrFromInt(frame.x0);
    const size = frame.x1;
    var pos: usize = 0;

    for (registry.programs) |entry| {

        if (!entry.listed) continue;

        const needed = entry.category.len + 1 + entry.name.len + 1 + entry.description.len + 1;

        if (pos + needed > size) break;

        @memcpy(buf[pos..][0..entry.category.len], entry.category);
        buf[pos + entry.category.len] = 0;
        pos += entry.category.len + 1;

        @memcpy(buf[pos..][0..entry.name.len], entry.name);
        buf[pos + entry.name.len] = 0;
        pos += entry.name.len + 1;

        @memcpy(buf[pos..][0..entry.description.len], entry.description);
        buf[pos + entry.description.len] = 0;
        pos += entry.description.len + 1;

    }

    return pos;

}

// chmod(name, anyone_read, anyone_write) -> 0 or negative error.
fn sys_chmod(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const anyone_read = frame.x1 != 0;
    const anyone_write = frame.x2 != 0;
    const name = name_ptr[0..str_len(name_ptr)];

    const pcb = scheduler.current_process();
    const fi = fs.find_entry_path(pcb.fs_cwd, name) orelse return @bitCast(@as(i64, -2)); // ENOENT

    fs.files[fi].permissions.anyone_read = anyone_read;
    fs.files[fi].permissions.anyone_write = anyone_write;

    fs.flush_entry(fi);
    return 0;

}

// delete(name) -> 0 or negative error.
fn sys_delete(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const name = name_ptr[0..str_len(name_ptr)];

    const pcb = scheduler.current_process();

    return @bitCast(@as(i64, fs.delete_file_path(pcb.fs_cwd, name, pcb.pid)));

}

// rename(old_name, new_name) -> 0 or negative error.
fn sys_rename(frame: *Frame) u64 {

    const old_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const new_ptr: [*:0]const u8 = @ptrFromInt(frame.x1);
    const old_name = old_ptr[0..str_len(old_ptr)];
    const new_name = new_ptr[0..str_len(new_ptr)];

    const pcb = scheduler.current_process();

    return @bitCast(@as(i64, fs.rename_path(pcb.fs_cwd, old_name, new_name, pcb.pid)));

}

// listfiles(buf, size, path?) -> bytes written. path null (x2=0) lists cwd.
// Writes name\0'f'|'d'\0size_string\0 per entry.
fn sys_listfiles(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const buf: [*]u8 = @ptrFromInt(frame.x0);
    const size = frame.x1;
    const path_ptr = frame.x2;

    const dir_ref: u8 = blk: {

        if (path_ptr == 0) break :blk pcb.fs_cwd;

        const path_z: [*:0]const u8 = @ptrFromInt(path_ptr);
        const path_slice = path_z[0..str_len(path_z)];

        break :blk fs.resolve_dir_for_list(pcb.fs_cwd, path_slice) orelse return 0;

    };

    return fs.list_dir(buf, size, dir_ref);

}

fn sys_chdir(frame: *Frame) u64 {

    const path_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const path = path_ptr[0..str_len(path_ptr)];

    return @bitCast(@as(i64, fs.chdir(scheduler.current_process(), path)));

}

fn sys_mkdir(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const name = name_ptr[0..str_len(name_ptr)];
    const pcb = scheduler.current_process();

    if (!fs.mkdir_path(pcb.fs_cwd, name, pcb.pid)) {
        return @bitCast(@as(i64, -28)); // ENOSPC / exists
    }

    return 0;

}

fn sys_rmdir(frame: *Frame) u64 {

    const name_ptr: [*:0]const u8 = @ptrFromInt(frame.x0);
    const name = name_ptr[0..str_len(name_ptr)];
    const pcb = scheduler.current_process();

    return @bitCast(@as(i64, fs.rmdir_path(pcb.fs_cwd, name, pcb.pid, pcb.fs_cwd)));

}

fn sys_getcwd(frame: *Frame) u64 {

    const pcb = scheduler.current_process();
    const buf: [*]u8 = @ptrFromInt(frame.x0);
    const size = frame.x1;

    return @bitCast(@as(i64, fs.getcwd(pcb, buf, size)));

}

// sysinfo(type, buf, size) -> bytes written. type: 0=scheduler, 1=memory.
fn sys_sysinfo(frame: *Frame) u64 {

    const info_type = frame.x0;
    const buf: [*]u8 = @ptrFromInt(frame.x1);
    const size = frame.x2;

    if (info_type == 0) return write_scheduler_info(buf, size);
    if (info_type == 1) return write_memory_info(buf, size);

    return 0;

}

fn write_scheduler_info(buf: [*]u8, size: usize) u64 {

    var w = BufWriter{ .buf = buf, .size = size };

    // Count active processes.
    var active: usize = 0;

    for (0..scheduler.process_count) |i| {

        const state = scheduler.processes[i].state;

        if (state != .empty and state != .zombie) active += 1;

    }

    w.str("Cores: ");
    w.int(scheduler.core_count);
    w.str("\r\n");
    w.str("Active Processes: ");
    w.int(active);
    w.str("/");
    w.int(scheduler.process_count);
    w.str(" slots\r\n\r\n");

    for (0..scheduler.process_count) |i| {

        const proc = &scheduler.processes[i];

        if (proc.state == .empty or proc.state == .zombie) continue;

        w.str("  PID ");
        w.int(proc.pid);

        // Pad to column.
        if (proc.pid < 10) w.str(" ");

        w.str("  ");

        switch (proc.state) {

            .ready => w.str("ready"),
            .running => w.str("running"),
            .blocked => w.str("blocked"),
            else => w.str("?"),

        }

        w.str("\r\n");

    }

    return w.pos;

}

fn write_memory_info(buf: [*]u8, size: usize) u64 {

    var w = BufWriter{ .buf = buf, .size = size };

    const total = physical_allocator.TOTAL_PAGES;
    const free = physical_allocator.free_page_count;
    const used = total - free;

    w.str("Physical Pages:\r\n");
    w.str("  Total:  ");
    w.int(total);
    w.str(" (");
    w.int(total * 4096 / 1024 / 1024);
    w.str(" MB)\r\n");
    w.str("  Used:   ");
    w.int(used);
    w.str("\r\n");
    w.str("  Free:   ");
    w.int(free);
    w.str("\r\n\r\n");

    w.str("Kernel Heap:\r\n");
    w.str("  Used:   ");
    w.int(heap.used_bytes());
    w.str(" / ");
    w.int(heap.capacity());
    w.str(" bytes\r\n");

    return w.pos;

}

/// Simple buffer writer for formatting sysinfo output.
const BufWriter = struct {

    buf: [*]u8,
    size: usize,
    pos: usize = 0,

    fn str(self: *BufWriter, s: []const u8) void {

        for (s) |c| {

            if (self.pos >= self.size) return;
            self.buf[self.pos] = c;
            self.pos += 1;

        }

    }

    fn int(self: *BufWriter, value: usize) void {

        if (value == 0) {
            self.str("0");
            return;
        }

        var num_buf: [20]u8 = undefined;
        var p: usize = 20;
        var v = value;

        while (v > 0) {
            p -= 1;
            num_buf[p] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }

        self.str(num_buf[p..20]);

    }

};

/// Resolve an ELF image for execve: ramfs `/programs/...`, then embedded name, then `/programs/<basename>` for bare names.
fn resolve_exec_elf(path: []const u8) ?[]const u8 {

    const pcb = scheduler.current_process();

    if (fs.resolve_program_elf_from_path(pcb.fs_cwd, path)) |elf| return elf;

    if (find_program(path)) |elf| return elf;

    if (std.mem.indexOfScalar(u8, path, '/') == null) {

        var buf: [48]u8 = undefined;
        const printed = std.fmt.bufPrint(&buf, "/programs/{s}", .{path}) catch return null;

        return fs.resolve_program_elf_from_path(fs.ROOT_DIR, printed);

    }

    return null;

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
