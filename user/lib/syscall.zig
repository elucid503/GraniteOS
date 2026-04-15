// user/lib/syscall.zig - Syscall interface for GraniteOS user space

pub const SYS_WRITE: usize = 1;
pub const SYS_READ: usize = 2;
pub const SYS_EXIT: usize = 3;
pub const SYS_GETPID: usize = 4;
pub const SYS_FORK: usize = 5;
pub const SYS_EXECVE: usize = 6;
pub const SYS_BRK: usize = 7;
pub const SYS_WAIT4: usize = 8;
pub const SYS_OPEN: usize = 9;
pub const SYS_CLOSE: usize = 10;
pub const SYS_PIPE: usize = 11;
pub const SYS_CREATE: usize = 12;
pub const SYS_KILL: usize = 13;
pub const SYS_SIGACTION: usize = 14;
pub const SYS_SIGRETURN: usize = 15;
pub const SYS_DUP2: usize = 16;
pub const SYS_LISTPROGS: usize = 17;
pub const SYS_DELETE: usize = 18;
pub const SYS_RENAME: usize = 19;
pub const SYS_LISTFILES: usize = 20;
pub const SYS_SYSINFO: usize = 21;
pub const SYS_CHMOD: usize = 22;
pub const SYS_CHDIR: usize = 23;
pub const SYS_MKDIR: usize = 24;
pub const SYS_RMDIR: usize = 25;
pub const SYS_GETCWD: usize = 26;
pub const SYS_DISKFORMAT: usize = 27;
pub const SYS_SEARCH: usize = 28;
pub const SYS_PATHCTL: usize = 29;
pub const SYS_GETPERMS: usize = 30;
pub const SYS_ISATTY: usize = 31;

pub const STDIN: usize = 0;
pub const STDOUT: usize = 1;
pub const STDERR: usize = 2;

pub const OPEN_READ: usize = 1;
pub const OPEN_WRITE: usize = 2;
pub const OPEN_READWRITE: usize = 3;

/// Write bytes to a file descriptor. Returns bytes written, or a negative error code.
pub fn write(fd: usize, buf: []const u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_WRITE,
        .x0 = fd,
        .x1 = @intFromPtr(buf.ptr),
        .x2 = buf.len,

    }));

}

/// Read bytes from a file descriptor into buf. Returns bytes read, or a negative error code.
pub fn read(fd: usize, buf: []u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_READ,
        .x0 = fd,
        .x1 = @intFromPtr(buf.ptr),
        .x2 = buf.len,

    }));

}

/// Exit the current process. Never returns.
pub fn exit(code: i32) noreturn {

    _ = raw(.{ .nr = SYS_EXIT, .x0 = @bitCast(@as(isize, code)) });
    unreachable;

}

/// Return the current process ID.
pub fn getpid() usize {

    return raw(.{ .nr = SYS_GETPID });

}

/// Adjust the process heap break. Pass 0 to query the current break.
/// Returns the new (or current) break address.
pub fn brk(addr: usize) usize {

    return raw(.{ .nr = SYS_BRK, .x0 = addr });

}

/// Fork the current process. Returns 0 in the child, child PID in the parent.
pub fn fork() isize {

    return @bitCast(raw(.{ .nr = SYS_FORK }));

}

/// Replace the current process image with the named embedded binary.
/// argv is a null-terminated array of null-terminated string pointers (or null for no args).
/// On success the new program receives argc in x0 and argv in x1.
pub fn execve(path: [*:0]const u8, argv: ?[*]const ?[*:0]const u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_EXECVE,
        .x0 = @intFromPtr(path),
        .x1 = if (argv) |a| @intFromPtr(a) else 0,
        .x2 = 0,

    }));

}

/// Block until the process with the given PID exits. Returns the PID.
pub fn waitpid(pid: usize) usize {

    return raw(.{ .nr = SYS_WAIT4, .x0 = pid });

}

/// Create a new empty file in the in-memory file system.
pub fn create(name: [*:0]const u8) isize {

    return @bitCast(raw(.{ .nr = SYS_CREATE, .x0 = @intFromPtr(name) }));

}

/// Open an existing file. flags: OPEN_READ=1, OPEN_WRITE=2, OPEN_READWRITE=3.
/// Returns the fd (>= 3) on success, or a negative error code.
pub fn open(name: [*:0]const u8, flags: usize) isize {

    return @bitCast(raw(.{

        .nr = SYS_OPEN,
        .x0 = @intFromPtr(name),
        .x1 = flags,

    }));

}

/// Close a file descriptor.
pub fn close(fd: usize) isize {

    return @bitCast(raw(.{ .nr = SYS_CLOSE, .x0 = fd }));

}

/// Create a pipe. Writes [read_fd, write_fd] into fds. Returns 0 on success.
pub fn pipe(fds: *[2]usize) isize {

    return @bitCast(raw(.{ .nr = SYS_PIPE, .x0 = @intFromPtr(fds) }));

}

/// Send a signal to a process. Returns 0 on success.
pub fn kill(pid: usize, sig: usize) isize {

    return @bitCast(raw(.{ .nr = SYS_KILL, .x0 = pid, .x1 = sig }));

}

/// Register a signal handler. Pass 0 as handler to restore default behavior.
pub fn sigaction(sig: usize, handler: usize) isize {

    return @bitCast(raw(.{ .nr = SYS_SIGACTION, .x0 = sig, .x1 = handler }));

}

/// Return from a signal handler. Restores the context from before signal delivery.
/// Must be called at the end of every signal handler. Never returns.
pub fn sigreturn() noreturn {

    _ = raw(.{ .nr = SYS_SIGRETURN });
    unreachable;

}

/// Redirect stdin (new_fd=0) or stdout (new_fd=1) to a pipe fd.
/// old_fd must be a pipe descriptor. Returns 0 on success.
pub fn dup2(old_fd: usize, new_fd: usize) isize {

    return @bitCast(raw(.{

        .nr = SYS_DUP2,
        .x0 = old_fd,
        .x1 = new_fd,

    }));

}

/// List embedded program names. Writes null-separated names into buf.
/// Returns total bytes written.
pub fn listprogs(buf: []u8) usize {

    return raw(.{

        .nr = SYS_LISTPROGS,
        .x0 = @intFromPtr(buf.ptr),
        .x1 = buf.len,

    });

}

/// Delete a file by name. Returns 0 on success, or a negative error code.
pub fn delete(name: [*:0]const u8) isize {

    return @bitCast(raw(.{ .nr = SYS_DELETE, .x0 = @intFromPtr(name) }));

}

/// Rename a file. Returns 0 on success, or a negative error code.
pub fn rename(old_name: [*:0]const u8, new_name: [*:0]const u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_RENAME,
        .x0 = @intFromPtr(old_name),
        .x1 = @intFromPtr(new_name),

    }));

}

/// List files in the current directory. Each entry: name\0kind\0size\0perms\0inode\0owner\0capacity\0
pub fn listfiles(buf: []u8) usize {

    return listfiles_in(buf, null);

}

/// List files in `dir_path` (null = current directory). `dir_path` must name an existing directory.
pub fn listfiles_in(buf: []u8, dir_path: ?[*:0]const u8) usize {

    return raw(.{

        .nr = SYS_LISTFILES,
        .x0 = @intFromPtr(buf.ptr),
        .x1 = buf.len,
        .x2 = if (dir_path) |p| @intFromPtr(p) else 0,

    });

}

/// Change the current working directory.
pub fn chdir(path: [*:0]const u8) isize {

    return @bitCast(raw(.{ .nr = SYS_CHDIR, .x0 = @intFromPtr(path) }));

}

/// Create a directory (supports nested paths such as `a/b`).
pub fn mkdir(path: [*:0]const u8) isize {

    return @bitCast(raw(.{ .nr = SYS_MKDIR, .x0 = @intFromPtr(path) }));

}

/// Remove an empty directory.
pub fn rmdir(path: [*:0]const u8) isize {

    return @bitCast(raw(.{ .nr = SYS_RMDIR, .x0 = @intFromPtr(path) }));

}

/// Write the absolute path of the current directory into `buf` (NUL-terminated). Returns byte count including NUL, or a negative error.
pub fn getcwd(buf: []u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_GETCWD,
        .x0 = @intFromPtr(buf.ptr),
        .x1 = buf.len,

    }));

}

/// Get system info. type: 0=scheduler, 1=memory, 2=disk. Returns bytes written.
pub fn sysinfo(info_type: usize, buf: []u8) usize {

    return raw(.{

        .nr = SYS_SYSINFO,
        .x0 = info_type,
        .x1 = @intFromPtr(buf.ptr),
        .x2 = buf.len,

    });

}

/// Wipe all user files from the in-memory FS and clear the persistent disk.
/// The default directory layout is restored in memory. Returns 0 on success.
pub fn diskformat() isize {

    return @bitCast(raw(.{ .nr = SYS_DISKFORMAT }));

}

/// Get current permissions of a file as a bitmask: bit0=read, bit1=write, bit2=exec, bit3=delete.
/// Returns the bitmask (0-15) or a negative error code.
pub fn getperms(name: [*:0]const u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_GETPERMS,
        .x0 = @intFromPtr(name),

    }));

}

/// Change file permissions via bitmask: bit0=read, bit1=write, bit2=exec, bit3=delete.
pub fn chmod(name: [*:0]const u8, mask: usize) isize {

    return @bitCast(raw(.{

        .nr = SYS_CHMOD,
        .x0 = @intFromPtr(name),
        .x1 = mask,

    }));

}

/// Search the filesystem. mode 0 = name substring, mode 1 = content substring.
/// Returns bytes written into buf (null-separated paths).
pub fn search(buf: []u8, query: [*:0]const u8, mode: usize) usize {

    return raw(.{

        .nr = SYS_SEARCH,
        .x0 = @intFromPtr(buf.ptr),
        .x1 = buf.len,
        .x2 = @intFromPtr(query),
        .x3 = mode,

    });

}

/// Manage the binary search path. op: 0=add, 1=remove, 2=list.
/// For add/remove: pass path as x1. For list: pass buf/size as x1/x2.
pub fn pathctl(op: usize, arg0: usize, arg1: usize) isize {

    return @bitCast(raw(.{

        .nr = SYS_PATHCTL,
        .x0 = op,
        .x1 = arg0,
        .x2 = arg1,

    }));

}

/// Return true if fd is connected to the UART terminal (not redirected to a pipe).
pub fn isatty(fd: usize) bool {

    return raw(.{ .nr = SYS_ISATTY, .x0 = fd }) == 1;

}

// Raw syscall: pass any subset of x0–x5 as arguments.
// Only fields set in Args are placed in registers; the rest default to 0.
const Args = struct {

    nr: usize,
    x0: usize = 0,
    x1: usize = 0,
    x2: usize = 0,
    x3: usize = 0,
    x4: usize = 0,
    x5: usize = 0,

};

fn raw(args: Args) usize {

    return asm volatile ("svc #0"

        : [ret] "={x0}" (-> usize),
        : [nr] "{x8}" (args.nr),
          [x0] "{x0}" (args.x0),
          [x1] "{x1}" (args.x1),
          [x2] "{x2}" (args.x2),
          [x3] "{x3}" (args.x3),
          [x4] "{x4}" (args.x4),
          [x5] "{x5}" (args.x5),
        : .{ .memory = true }

    );

}
