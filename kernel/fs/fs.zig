// kernel/fs/fs.zig - GraniteOS in-memory file system

const heap = @import("../memory/heap.zig");
const scheduler = @import("../scheduler/scheduler.zig");

pub const MAX_FILES: usize = 32;
pub const MAX_PIPES: usize = 8;
pub const MAX_NAME: usize = 31;
pub const FILE_CAPACITY: usize = 4096;
pub const PIPE_CAPACITY: usize = 4096;

pub const FIRST_FD: usize = 3;

pub const FileKind = enum { empty, file };

pub const Permissions = struct {

    owner_read: bool = true,
    owner_write: bool = true,
    anyone_read: bool = true,
    anyone_write: bool = false,

};

pub const FileEntry = struct {

    name: [MAX_NAME + 1]u8 = undefined,
    name_len: u8 = 0,

    kind: FileKind = .empty,

    owner: u32 = 0,

    size: usize = 0,
    capacity: usize = 0,

    data: ?[*]u8 = null,

    permissions: Permissions = .{},

};

pub const Pipe = struct {

    buffer: [PIPE_CAPACITY]u8 = undefined,

    read_pos: usize = 0,
    write_pos: usize = 0,

    count: usize = 0,

    reader_count: u8 = 0,
    writer_count: u8 = 0,

    active: bool = false,

};

pub const ReadResult = struct {

    bytes: usize = 0,
    block: bool = false,

};

pub const PipeFds = struct {

    read_fd: usize,
    write_fd: usize,

};

var files: [MAX_FILES]FileEntry = undefined;
pub var pipes: [MAX_PIPES]Pipe = undefined;

pub fn init() void {

    for (&files) |*f| f.kind = .empty;
    for (&pipes) |*p| p.active = false;

}

/// Create a new empty file. Returns true on success.
pub fn create_file(name: []const u8, owner: u32) bool {

    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (find_file(name) != null) return false;

    for (&files) |*f| {

        if (f.kind != .empty) continue;

        const buf = heap.alloc(FILE_CAPACITY, 8) orelse return false;

        f.kind = .file;
        f.owner = owner;
        f.size = 0;
        f.capacity = FILE_CAPACITY;
        f.data = buf;
        f.name_len = @intCast(name.len);
        f.permissions = .{};

        @memcpy(f.name[0..name.len], name);
        f.name[name.len] = 0;

        return true;

    }

    return false;

}

/// Open an existing file by name. Returns the fd (>= 3) or a negative error.
pub fn open_file(pcb: *scheduler.PCB, name: []const u8, read: bool, write: bool) isize {

    const fi = find_file(name) orelse return -2; // ENOENT

    const entry = &files[fi];
    const is_owner = (entry.owner == pcb.pid);

    if (read and !((is_owner and entry.permissions.owner_read) or entry.permissions.anyone_read))
        return -13; // EACCES

    if (write and !((is_owner and entry.permissions.owner_write) or entry.permissions.anyone_write))
        return -13;

    const fd_idx = alloc_fd(pcb) orelse return -24; // EMFILE

    pcb.file_descriptors[fd_idx] = .{

        .active = true,
        .kind = .file,
        .entry = @intCast(fi),
        .offset = 0,
        .can_read = read,
        .can_write = write,

    };

    return @intCast(fd_idx + FIRST_FD);

}

/// Close a file descriptor. Returns 0 on success or a negative error.
pub fn close_fd(pcb: *scheduler.PCB, fd: usize) isize {

    if (fd < FIRST_FD) return -9; // EBADF

    const idx = fd - FIRST_FD;
    if (idx >= scheduler.MAX_OPEN_FILES) return -9;

    const desc = &pcb.file_descriptors[idx];
    if (!desc.active) return -9;

    if (desc.kind == .pipe) {

        const pipe = &pipes[desc.entry];

        if (desc.can_read and pipe.reader_count > 0) pipe.reader_count -= 1;

        if (desc.can_write and pipe.writer_count > 0) {

            pipe.writer_count -= 1;

            // Wake readers so they see EOF (writer_count is now 0)
            if (pipe.writer_count == 0) scheduler.wake_pipe_waiters(desc.entry);

        }

        if (pipe.reader_count == 0 and pipe.writer_count == 0) pipe.active = false;

    }

    desc.active = false;
    desc.kind = .none;

    return 0;

}

/// Close all open file descriptors for a process.
pub fn close_all(pcb: *scheduler.PCB) void {

    for (0..scheduler.MAX_OPEN_FILES) |i| {

        if (pcb.file_descriptors[i].active) {
            _ = close_fd(pcb, i + FIRST_FD);
        }

    }

}

/// Increment pipe reference counts for fds inherited across fork.
pub fn on_fork(child: *scheduler.PCB) void {

    for (&child.file_descriptors) |*desc| {

        if (!desc.active or desc.kind != .pipe) continue;

        const pipe = &pipes[desc.entry];
        if (desc.can_read) pipe.reader_count += 1;
        if (desc.can_write) pipe.writer_count += 1;

    }

}

// --- File read/write ---

pub fn file_read(desc: *scheduler.FdEntry, buf: [*]u8, count: usize) usize {

    const entry = &files[desc.entry];
    const remaining = entry.size -| desc.offset;
    const n = @min(count, remaining);

    if (n == 0) return 0;

    const src: [*]const u8 = entry.data orelse return 0;
    @memcpy(buf[0..n], src[desc.offset..][0..n]);

    desc.offset += n;
    return n;

}

pub fn file_write(desc: *scheduler.FdEntry, buf: [*]const u8, count: usize) usize {

    const entry = &files[desc.entry];
    const remaining = entry.capacity -| desc.offset;
    const n = @min(count, remaining);

    if (n == 0) return 0;

    const dst: [*]u8 = entry.data orelse return 0;
    @memcpy(dst[desc.offset..][0..n], buf[0..n]);

    desc.offset += n;
    if (desc.offset > entry.size) entry.size = desc.offset;

    return n;

}

/// Create a pipe and allocate read/write fds in the given process.
pub fn create_pipe(pcb: *scheduler.PCB) ?PipeFds {

    var pipe_idx: ?u8 = null;

    for (0..MAX_PIPES) |i| {

        if (!pipes[i].active) {
            pipe_idx = @intCast(i);
            break;
        }

    }

    const pi = pipe_idx orelse return null;

    const read_idx = alloc_fd(pcb) orelse return null;
    pcb.file_descriptors[read_idx].active = true; // reserve slot before second alloc

    const write_idx = alloc_fd(pcb) orelse {
        pcb.file_descriptors[read_idx].active = false;
        return null;
    };

    pipes[pi] = .{

        .buffer = undefined,
        .read_pos = 0,
        .write_pos = 0,
        .count = 0,
        .reader_count = 1,
        .writer_count = 1,
        .active = true,

    };

    pcb.file_descriptors[read_idx] = .{

        .active = true,
        .kind = .pipe,
        .entry = pi,
        .offset = 0,
        .can_read = true,
        .can_write = false,

    };

    pcb.file_descriptors[write_idx] = .{

        .active = true,
        .kind = .pipe,
        .entry = pi,
        .offset = 0,
        .can_read = false,
        .can_write = true,

    };

    return .{

        .read_fd = read_idx + FIRST_FD,
        .write_fd = write_idx + FIRST_FD,

    };

}

/// Read from a pipe. Returns bytes read, or signals the caller to block.
pub fn pipe_read(pipe_idx: u8, buf: [*]u8, count: usize) ReadResult {

    const pipe = &pipes[pipe_idx];

    if (pipe.count == 0) {

        // No data: block if writers exist, otherwise EOF
        if (pipe.writer_count > 0) return .{ .block = true };
        return .{ .bytes = 0 };

    }

    var n: usize = 0;

    while (n < count and pipe.count > 0) {

        buf[n] = pipe.buffer[pipe.read_pos];
        pipe.read_pos = (pipe.read_pos + 1) % PIPE_CAPACITY;
        pipe.count -= 1;
        n += 1;

    }

    return .{ .bytes = n };

}

/// Write to a pipe. Returns bytes written (0 if no readers or buffer full).
pub fn pipe_write(pipe_idx: u8, buf: [*]const u8, count: usize) usize {

    const pipe = &pipes[pipe_idx];

    if (pipe.reader_count == 0) return 0;

    var n: usize = 0;

    while (n < count and pipe.count < PIPE_CAPACITY) {

        pipe.buffer[pipe.write_pos] = buf[n];
        pipe.write_pos = (pipe.write_pos + 1) % PIPE_CAPACITY;
        pipe.count += 1;
        n += 1;

    }

    return n;

}

fn find_file(name: []const u8) ?usize {

    for (0..MAX_FILES) |i| {

        if (files[i].kind == .empty) continue;
        if (files[i].name_len != name.len) continue;

        if (mem_eql(files[i].name[0..files[i].name_len], name)) return i;

    }

    return null;

}

fn alloc_fd(pcb: *scheduler.PCB) ?usize {

    for (0..scheduler.MAX_OPEN_FILES) |i| {

        if (!pcb.file_descriptors[i].active) return i;

    }

    return null;

}

fn mem_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
