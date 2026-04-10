// user/lib/syscall.zig - Syscall interface for GraniteOS user space

pub const SYS_WRITE: usize = 1;
pub const SYS_READ: usize = 2;
pub const SYS_EXIT: usize = 3;
pub const SYS_GETPID: usize = 4;
pub const SYS_FORK: usize = 5;
pub const SYS_EXECVE: usize = 6;
pub const SYS_BRK: usize = 7;
pub const SYS_WAIT4: usize = 8;

pub const STDIN: usize = 0;
pub const STDOUT: usize = 1;
pub const STDERR: usize = 2;

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
