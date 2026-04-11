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
/// argv and envp are unused; pass null for both.
pub fn execve(path: [*:0]const u8) isize {

    return @bitCast(raw(.{

        .nr = SYS_EXECVE,
        .x0 = @intFromPtr(path),
        .x1 = 0,
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
