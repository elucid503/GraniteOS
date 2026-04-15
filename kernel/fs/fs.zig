// kernel/fs/fs.zig - GraniteOS in-memory hierarchical file system

const heap = @import("../memory/heap.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const embedded = @import("user_programs");
const sync = @import("../sync/mutex.zig");
const persist = @import("persist.zig");
const index = @import("index.zig");

/// Protects all file and pipe table mutations.
var fs_lock: sync.Mutex = .{};

pub const MAX_FILES: usize = 64;
pub const MAX_PIPES: usize = 8;
pub const MAX_NAME: usize = 31;
pub const FILE_CAPACITY: usize = 4096;
pub const PIPE_CAPACITY: usize = 4096;

pub const FIRST_FD: usize = 3;

/// Sentinel: logical root (not a slot index). Entries directly under root use this as `parent`.
pub const ROOT_DIR: u8 = 0xFF;

pub const MAX_PATH_SEGMENTS: usize = 16;

pub const FileKind = enum { empty, file, directory, program };

pub const Permissions = struct {

    can_read: bool = true,
    can_write: bool = false,
    can_exec: bool = false,
    can_delete: bool = false,

};

pub const FileEntry = struct {

    name: [MAX_NAME + 1]u8 = undefined,
    name_len: u8 = 0,

    /// Parent directory: inode index of parent, or `ROOT_DIR` for root-level entries.
    parent: u8 = ROOT_DIR,

    kind: FileKind = .empty,

    owner: u32 = 0,

    size: usize = 0,
    capacity: usize = 0,

    data: ?[*]u8 = null,

    /// When `kind == .program`, index into `embedded.programs` (ELF image).
    program_index: u8 = 0,

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

pub var files: [MAX_FILES]FileEntry = undefined;
pub var pipes: [MAX_PIPES]Pipe = undefined;

// Binary search path: directories searched when resolving bare command names.

pub const MAX_PATH_ENTRIES: usize = 16;
pub const MAX_PATH_LEN: usize = 64;

pub const PathEntry = struct {

    path: [MAX_PATH_LEN]u8 = undefined,
    len: usize = 0,
    active: bool = false,

};

pub var search_path: [MAX_PATH_ENTRIES]PathEntry = [_]PathEntry{.{}} ** MAX_PATH_ENTRIES;

pub fn init() void {

    for (&files) |*f| {

        f.kind = .empty;
        f.parent = ROOT_DIR;
        f.program_index = 0;

    }

    for (&pipes) |*p| p.active = false;

    populate_default_layout();

}

/// Root layout: `/programs` (embedded user ELFs), `/config`, `/temp`, `/dev`, and `/config/motd`.
/// Called during init (single-threaded) - no locking needed.
fn populate_default_layout() void {

    _ = mkdir_in_locked(ROOT_DIR, "programs", 0);
    _ = mkdir_in_locked(ROOT_DIR, "config", 0);
    _ = mkdir_in_locked(ROOT_DIR, "temp", 0);
    _ = mkdir_in_locked(ROOT_DIR, "dev", 0);

    const prog_dir: u8 = @intCast(find_child_any(ROOT_DIR, "programs") orelse return);

    for (embedded.programs, 0..) |prog, i| {

        if (i > 255) break;
        _ = install_program_under(prog_dir, prog.name, @intCast(i), prog.elf.len);

    }

    const cfg_idx: u8 = @intCast(find_child_any(ROOT_DIR, "config") orelse return);

    if (!create_file_in_locked(cfg_idx, "motd", 0)) return;

    const motd_i = find_child_any(cfg_idx, "motd") orelse return;
    const motd = &files[motd_i];

    if (motd.kind == .file) {

        const msg = "Welcome to GraniteOS.\r\n"; // some default content

        if (motd.data) |d| {

            const c = @min(msg.len, motd.capacity);
            @memcpy(d[0..c], msg[0..c]);
            motd.size = c;

        }

    }

}

fn install_program_under(parent: u8, name: []const u8, program_index: u8, elf_len: usize) bool {

    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (!is_valid_parent(parent)) return false;
    if (find_child_any(parent, name) != null) return false;

    for (&files) |*f| {

        if (f.kind != .empty) continue;

        f.kind = .program;
        f.parent = parent;
        f.owner = 0;
        f.size = elf_len;
        f.capacity = 0;
        f.data = null;
        f.program_index = program_index;
        f.name_len = @intCast(name.len);
        f.permissions = .{ .can_read = true, .can_exec = true };

        @memcpy(f.name[0..name.len], name);
        f.name[name.len] = 0;

        return true;

    }

    return false;

}

/// If `path` resolves to an embedded program inode, return its ELF bytes.
pub fn resolve_program_elf_from_path(cwd: u8, path: []const u8) ?[]const u8 {

    fs_lock.lock();
    defer fs_lock.unlock();

    const resolved = resolve_existing_entry(cwd, path) orelse return null;
    const entry = &files[resolved.index];

    if (entry.kind != .program) return null;
    if (!entry.permissions.can_exec) return null;
    if (entry.program_index >= embedded.programs.len) return null;

    return embedded.programs[entry.program_index].elf;

}

/// Create a new empty file in `parent` (use `ROOT_DIR` or a directory inode index). Returns true on success.
pub fn create_file_in(parent: u8, name: []const u8, owner: u32) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    return create_file_in_locked(parent, name, owner);

}

/// Internal create - caller must hold fs_lock.
fn create_file_in_locked(parent: u8, name: []const u8, owner: u32) bool {

    if (!is_valid_name(name)) return false;
    if (!is_valid_parent(parent)) return false;
    if (find_child_any(parent, name) != null) return false;

    for (0..MAX_FILES) |i| {

        if (files[i].kind != .empty) continue;

        const buf = heap.alloc(FILE_CAPACITY, 8) orelse return false;

        files[i].kind = .file;
        files[i].parent = parent;
        files[i].owner = owner;
        files[i].size = 0;
        files[i].capacity = FILE_CAPACITY;
        files[i].data = buf;
        files[i].name_len = @intCast(name.len);
        files[i].permissions = .{};

        @memcpy(files[i].name[0..name.len], name);
        files[i].name[name.len] = 0;

        persist.save_entry(i);
        index.invalidate();
        return true;

    }

    return false;

}

fn is_valid_name(name: []const u8) bool {

    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (str_eql(name, ".") or str_eql(name, "..")) return false;

    return true;

}

/// Create an empty directory under `parent`. Returns true on success.
pub fn mkdir_in(parent: u8, name: []const u8, owner: u32) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    return mkdir_in_locked(parent, name, owner);

}

/// Internal mkdir - caller must hold fs_lock.
fn mkdir_in_locked(parent: u8, name: []const u8, owner: u32) bool {

    if (!is_valid_name(name)) return false;
    if (!is_valid_parent(parent)) return false;
    if (find_child_any(parent, name) != null) return false;

    for (0..MAX_FILES) |i| {

        if (files[i].kind != .empty) continue;

        files[i].kind = .directory;
        files[i].parent = parent;
        files[i].owner = owner;
        files[i].size = 0;
        files[i].capacity = 0;
        files[i].data = null;
        files[i].name_len = @intCast(name.len);
        files[i].permissions = .{};

        @memcpy(files[i].name[0..name.len], name);
        files[i].name[name.len] = 0;

        persist.save_entry(i);
        index.invalidate();
        return true;

    }

    return false;

}

fn is_valid_parent(parent: u8) bool {

    if (parent == ROOT_DIR) return true;
    if (parent >= MAX_FILES) return false;
    return files[parent].kind == .directory;

}

/// Open an existing file by path (relative to `pcb.fs_cwd` or absolute). Returns the fd (>= 3) or a negative error.
pub fn open_file(pcb: *scheduler.PCB, path: []const u8, read: bool, write: bool) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const resolved = resolve_existing_entry(pcb.fs_cwd, path) orelse return -2; // ENOENT
    const fi = resolved.index;
    const entry = &files[fi];

    if (entry.kind == .directory) return -21; // EISDIR
    if (entry.kind != .file and entry.kind != .program) return -22; // EINVAL

    if (read and !entry.permissions.can_read)
        return -13; // EACCES

    if (write and !entry.permissions.can_write)
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

    fs_lock.lock();
    defer fs_lock.unlock();

    return close_fd_locked(pcb, fd);

}

/// Internal close - caller must hold fs_lock.
fn close_fd_locked(pcb: *scheduler.PCB, fd: usize) isize {

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

    fs_lock.lock();
    defer fs_lock.unlock();

    for (0..scheduler.MAX_OPEN_FILES) |i| {

        if (pcb.file_descriptors[i].active) {
            _ = close_fd_locked(pcb, i + FIRST_FD);
        }

    }

}

/// Increment pipe reference counts for fds inherited across fork.
pub fn on_fork(child: *scheduler.PCB) void {

    fs_lock.lock();
    defer fs_lock.unlock();

    for (&child.file_descriptors) |*desc| {

        if (!desc.active or desc.kind != .pipe) continue;

        const pipe = &pipes[desc.entry];
        if (desc.can_read) pipe.reader_count += 1;
        if (desc.can_write) pipe.writer_count += 1;

    }

}

// File read/write

pub fn file_read(desc: *scheduler.FdEntry, buf: [*]u8, count: usize) usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const entry = &files[desc.entry];
    const remaining = entry.size -| desc.offset;
    const n = @min(count, remaining);

    if (n == 0) return 0;

    if (entry.kind == .program) {

        if (entry.program_index >= embedded.programs.len) return 0;

        const elf = embedded.programs[entry.program_index].elf;
        @memcpy(buf[0..n], elf[desc.offset..][0..n]);

        desc.offset += n;
        return n;

    }

    const src: [*]const u8 = entry.data orelse return 0;
    @memcpy(buf[0..n], src[desc.offset..][0..n]);

    desc.offset += n;
    return n;

}

pub fn file_write(desc: *scheduler.FdEntry, buf: [*]const u8, count: usize) usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const entry = &files[desc.entry];

    if (entry.kind == .program) return 0;

    const remaining = entry.capacity -| desc.offset;
    const n = @min(count, remaining);

    if (n == 0) return 0;

    const dst: [*]u8 = entry.data orelse return 0;
    @memcpy(dst[desc.offset..][0..n], buf[0..n]);

    desc.offset += n;
    if (desc.offset > entry.size) entry.size = desc.offset;

    persist.save_entry(desc.entry);
    return n;

}

/// Create a pipe and allocate read/write fds in the given process.
pub fn create_pipe(pcb: *scheduler.PCB) ?PipeFds {

    fs_lock.lock();
    defer fs_lock.unlock();

    var pipe_idx: ?u8 = null;

    for (0..MAX_PIPES) |i| {

        if (!pipes[i].active) {
            pipe_idx = @intCast(i);
            break;
        }

    }

    const pi = pipe_idx orelse return null;

    const read_idx = alloc_fd(pcb) orelse return null;
    pcb.file_descriptors[read_idx].active = true;

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

    fs_lock.lock();
    defer fs_lock.unlock();

    const pipe = &pipes[pipe_idx];

    if (pipe.count == 0) {

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

    fs_lock.lock();
    defer fs_lock.unlock();

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

/// Delete a regular file by path. Only the owner may delete. Returns 0 or negative error.
pub fn delete_file_path(cwd: u8, path: []const u8) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const resolved = resolve_existing_entry(cwd, path) orelse return -2;
    const entry = &files[resolved.index];

    if (entry.kind == .program) return -13; // cannot delete embedded binaries
    if (entry.kind != .file) return -21; // EISDIR
    if (!entry.permissions.can_delete) return -13; // EACCES

    entry.kind = .empty;
    entry.data = null;

    persist.save_entry(resolved.index);
    index.invalidate();
    return 0;

}

/// Remove a directory and everything beneath it (recursive). Only the owner may remove.
/// `working_dir` is the process cwd inode: cannot remove that directory or any ancestor of cwd.
pub fn rmdir_path(cwd: u8, path: []const u8, caller_pid: u32, working_dir: u8) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const resolved = resolve_existing_entry(cwd, path) orelse return -2;
    const di: u8 = @intCast(resolved.index);
    const entry = &files[di];

    if (entry.kind != .directory) return -20; // ENOTDIR
    if (entry.owner != caller_pid) return -13;

    if (!dir_tree_owned_by(di, caller_pid)) return -13;

    const result = remove_dir_recursive(di, caller_pid, working_dir);
    if (result == 0) index.invalidate();
    return result;

}

/// True if `di` and every descendant is owned by `caller_pid`.
fn dir_tree_owned_by(di: u8, caller_pid: u32) bool {

    var i: usize = 0;

    while (i < MAX_FILES) : (i += 1) {

        if (files[i].kind == .empty) continue;
        if (files[i].parent != di) continue;

        if (files[i].owner != caller_pid) return false;

        if (files[i].kind == .directory and !dir_tree_owned_by(@intCast(i), caller_pid)) return false;

    }

    return true;

}

/// True if `working_dir` is `dir` or a descendant of `dir` (cannot delete `dir` without leaving cwd dangling).
fn cwd_blocks_removal_of(working_dir: u8, dir: u8) bool {

    if (working_dir == ROOT_DIR) return false;

    var cur = working_dir;

    while (cur != ROOT_DIR) {

        if (cur == dir) return true;
        if (cur >= MAX_FILES) return false;

        cur = files[cur].parent;

    }

    return false;

}

/// Deletes directory inode `di` and all descendants. Checks owner and cwd on every directory removed.
fn remove_dir_recursive(di: u8, caller_pid: u32, working_dir: u8) isize {

    if (di >= MAX_FILES or files[di].kind != .directory) return -20;

    if (cwd_blocks_removal_of(working_dir, di)) return -16;

    var i: usize = 0;

    while (i < MAX_FILES) : (i += 1) {

        if (files[i].kind == .empty) continue;
        if (files[i].parent != di) continue;

        if (files[i].kind == .file) {

            files[i].kind = .empty;
            files[i].data = null;
            persist.save_entry(i);

        } else if (files[i].kind == .program) {

            files[i].kind = .empty;
            persist.save_entry(i);

        } else {

            const err = remove_dir_recursive(@intCast(i), caller_pid, working_dir);
            if (err != 0) return err;

        }

    }

    files[di].kind = .empty;
    persist.save_entry(di);

    return 0;

}

/// Rename/move a path. Only the owner may rename. Returns 0 or negative error.
pub fn rename_path(cwd: u8, old_path: []const u8, new_path: []const u8, caller_pid: u32) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const old_res = resolve_existing_entry(cwd, old_path) orelse return -2;
    const fi = old_res.index;
    const entry = &files[fi];

    if (entry.kind == .program) return -13;
    if (entry.owner != caller_pid) return -13;

    const new_loc = resolve_parent_and_basename(cwd, new_path) orelse return -22;
    if (!is_valid_name(new_loc.basename)) return -22;
    if (!is_valid_parent(new_loc.parent)) return -22;

    if (find_child_any(new_loc.parent, new_loc.basename)) |existing| {

        if (existing != fi) return -17; // EEXIST

    }

    entry.parent = new_loc.parent;
    entry.name_len = @intCast(new_loc.basename.len);
    @memcpy(entry.name[0..new_loc.basename.len], new_loc.basename);
    entry.name[new_loc.basename.len] = 0;

    persist.save_entry(fi);
    index.invalidate();
    return 0;

}

/// Write directory listing for `dir_ref` (`ROOT_DIR` or a directory inode) into buf.
/// Each entry: name\0'f'|'d'\0size_decimal\0perms_decimal\0inode_decimal\0owner_decimal\0capacity_decimal\0
/// perms_decimal encodes Permissions as bitmask: bit0=read bit1=write bit2=exec bit3=delete
pub fn list_dir(buf: [*]u8, size: usize, dir_ref: u8) usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    if (dir_ref != ROOT_DIR and (dir_ref >= MAX_FILES or files[dir_ref].kind != .directory)) return 0;

    var pos: usize = 0;

    for (&files, 0..) |*f, fi| {

        if (f.kind == .empty) continue;
        if (f.parent != dir_ref) continue;

        const name = f.name[0..f.name_len];
        const kind_ch: u8 = if (f.kind == .directory) 'd' else 'f';

        var num_buf: [20]u8 = undefined;
        const num_str = if (f.kind == .directory)
            @as([]const u8, "-")
        else
            format_int(f.size, &num_buf);

        const perms_val: usize =
            (@as(usize, if (f.permissions.can_read) 1 else 0)) |
            (@as(usize, if (f.permissions.can_write) 1 else 0) << 1) |
            (@as(usize, if (f.permissions.can_exec) 1 else 0) << 2) |
            (@as(usize, if (f.permissions.can_delete) 1 else 0) << 3);
        var perms_buf: [20]u8 = undefined;
        const perms_str = format_int(perms_val, &perms_buf);

        var inode_buf: [20]u8 = undefined;
        const inode_str = format_int(fi, &inode_buf);

        var owner_buf: [20]u8 = undefined;
        const owner_str = format_int(f.owner, &owner_buf);

        var cap_buf: [20]u8 = undefined;
        const cap_str = format_int(f.capacity, &cap_buf);

        const needed = name.len + 1 + 1 + 1 + num_str.len + 1 +
            perms_str.len + 1 + inode_str.len + 1 +
            owner_str.len + 1 + cap_str.len + 1;

        if (pos + needed > size) break;

        @memcpy(buf[pos..][0..name.len], name);
        buf[pos + name.len] = 0;
        pos += name.len + 1;

        buf[pos] = kind_ch;
        buf[pos + 1] = 0;
        pos += 2;

        @memcpy(buf[pos..][0..num_str.len], num_str);
        buf[pos + num_str.len] = 0;
        pos += num_str.len + 1;

        @memcpy(buf[pos..][0..perms_str.len], perms_str);
        buf[pos + perms_str.len] = 0;
        pos += perms_str.len + 1;

        @memcpy(buf[pos..][0..inode_str.len], inode_str);
        buf[pos + inode_str.len] = 0;
        pos += inode_str.len + 1;

        @memcpy(buf[pos..][0..owner_str.len], owner_str);
        buf[pos + owner_str.len] = 0;
        pos += owner_str.len + 1;

        @memcpy(buf[pos..][0..cap_str.len], cap_str);
        buf[pos + cap_str.len] = 0;
        pos += cap_str.len + 1;

    }

    return pos;

}

/// Resolve a directory path for listing. Returns directory inode or `ROOT_DIR`.
pub fn resolve_dir_for_list(cwd: u8, path_opt: ?[]const u8) ?u8 {

    fs_lock.lock();
    defer fs_lock.unlock();

    const p = path_opt orelse return cwd;

    if (p.len == 0) return cwd;

    if (p.len == 1 and p[0] == '/') return ROOT_DIR;

    const resolved = resolve_existing_entry(cwd, p) orelse return null;
    if (files[resolved.index].kind != .directory) return null;

    return @intCast(resolved.index);

}

/// Change current working directory. Returns 0 or negative error.
pub fn chdir(pcb: *scheduler.PCB, path: []const u8) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    if (path.len == 0) return -22;

    if (path.len == 1 and path[0] == '/') {

        pcb.fs_cwd = ROOT_DIR;
        return 0;

    }

    if (str_eql(path, ".")) return 0;

    if (str_eql(path, "..")) {

        pcb.fs_cwd = parent_of_cwd(pcb.fs_cwd);
        return 0;

    }

    const resolved = resolve_existing_entry(pcb.fs_cwd, path) orelse return -2;
    const idx = resolved.index;

    if (files[idx].kind != .directory) return -20; // ENOTDIR

    pcb.fs_cwd = @intCast(idx);
    return 0;

}

/// Format absolute path for `pcb.fs_cwd` into buf (NUL-terminated on success). Returns bytes written including NUL, or negative error.
pub fn getcwd(pcb: *scheduler.PCB, buf: [*]u8, buf_size: usize) isize {

    fs_lock.lock();
    defer fs_lock.unlock();

    if (buf_size == 0) return -22;

    if (pcb.fs_cwd == ROOT_DIR) {

        if (buf_size < 2) return -34; // ERANGE
        buf[0] = '/';
        buf[1] = 0;
        return 2;

    }

    var parts: [MAX_PATH_SEGMENTS][]const u8 = undefined;
    var count: usize = 0;

    var cur: u8 = pcb.fs_cwd;

    while (cur != ROOT_DIR) {

        if (cur >= MAX_FILES or files[cur].kind != .directory) return -2;

        if (count >= MAX_PATH_SEGMENTS) return -22;

        parts[count] = files[cur].name[0..files[cur].name_len];
        count += 1;
        cur = files[cur].parent;

    }

    var pos: usize = 0;

    var i = count;

    while (i > 0) {

        i -= 1;
        const seg = parts[i];

        if (pos + 1 + seg.len > buf_size - 1) return -34;

        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..seg.len], seg);
        pos += seg.len;

    }

    if (pos == 0) {

        if (buf_size < 2) return -34;
        buf[0] = '/';
        buf[1] = 0;
        return 2;

    }

    buf[pos] = 0;
    return @intCast(pos + 1);

}

/// Create file at path (relative to cwd or absolute). Returns true on success.
pub fn create_file_path(cwd: u8, path: []const u8, owner: u32) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    const loc = resolve_parent_and_basename(cwd, path) orelse return false;
    if (loc.basename.len == 0 or loc.basename.len > MAX_NAME) return false;

    return create_file_in_locked(loc.parent, loc.basename, owner);

}

/// Create directory at path. Returns true on success.
pub fn mkdir_path(cwd: u8, path: []const u8, owner: u32) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    const loc = resolve_parent_and_basename(cwd, path) orelse return false;
    if (loc.basename.len == 0 or loc.basename.len > MAX_NAME) return false;

    return mkdir_in_locked(loc.parent, loc.basename, owner);

}

/// Look up an entry by full path from cwd (for chmod, etc.). Returns slot index or null.
pub fn find_entry_path(cwd: u8, path: []const u8) ?usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    const r = resolve_existing_entry(cwd, path) orelse return null;
    return r.index;

}

/// Flush a single file entry to persistent storage (for external callers like chmod).
pub fn flush_entry(slot: usize) void {

    persist.save_entry(slot);

}

/// Wipe all user files and directories from the in-memory FS, then restore the default layout.
/// Program entries are cleared and re-installed by populate_default_layout.
pub fn format_user_files() void {

    fs_lock.lock();
    defer fs_lock.unlock();

    for (&files) |*f| {

        f.kind = .empty;
        f.data = null;
        f.size = 0;
        f.capacity = 0;

    }

    populate_default_layout();
    index.invalidate();

}

fn parent_of_cwd(cwd: u8) u8 {

    if (cwd == ROOT_DIR) return ROOT_DIR;
    if (cwd >= MAX_FILES) return ROOT_DIR;

    return files[cwd].parent;

}

const ResolvedEntry = struct { index: usize };

fn resolve_existing_entry(cwd: u8, path: []const u8) ?ResolvedEntry {

    const loc = resolve_parent_and_basename(cwd, path) orelse return null;
    const idx = find_child_any(loc.parent, loc.basename) orelse return null;

    return .{ .index = idx };

}

const ParentBasename = struct {

    parent: u8,
    basename: []const u8,

};

fn resolve_parent_and_basename(cwd: u8, path: []const u8) ?ParentBasename {

    var abs = false;
    var rest = path;

    if (rest.len > 0 and rest[0] == '/') {

        abs = true;
        rest = rest[1..];

    }

    while (rest.len > 0 and rest[rest.len - 1] == '/') {

        rest = rest[0 .. rest.len - 1]; // trim trailing slashes

    }

    var segs: [MAX_PATH_SEGMENTS][]const u8 = undefined;
    var seg_count: usize = 0;

    var start: usize = 0;
    var i: usize = 0;

    while (i <= rest.len) : (i += 1) {

        const at_end = (i == rest.len);
        const is_slash = !at_end and rest[i] == '/';

        if (at_end or is_slash) {

            if (i > start) {

                if (seg_count >= MAX_PATH_SEGMENTS) return null;
                segs[seg_count] = rest[start..i];
                seg_count += 1;

            }

            start = i + 1;

        }

    }

    if (seg_count == 0) {

        if (abs) return null;
        return null;

    }

    var cur: u8 = if (abs) ROOT_DIR else cwd;

    for (segs[0 .. seg_count - 1]) |comp| {

        cur = walk_one_component(cur, comp) orelse return null;

    }

    return .{

        .parent = cur,
        .basename = segs[seg_count - 1],

    };

}

fn walk_one_component(cur: u8, comp: []const u8) ?u8 {

    if (comp.len == 1 and comp[0] == '.') return cur;

    if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {

        return if (cur == ROOT_DIR) ROOT_DIR else files[cur].parent;

    }

    const idx = find_child_any(cur, comp) orelse return null;
    if (files[idx].kind != .directory) return null;

    return @intCast(idx);

}

fn find_child_any(parent: u8, name: []const u8) ?usize {

    for (0..MAX_FILES) |i| {

        if (files[i].kind == .empty) continue;
        if (files[i].parent != parent) continue;
        if (files[i].name_len != name.len) continue;

        if (mem_eql(files[i].name[0..files[i].name_len], name)) return i;

    }

    return null;

}

fn format_int(value: usize, buf: *[20]u8) []const u8 {

    if (value == 0) {

        buf[19] = '0';
        return buf[19..20];

    }

    var pos: usize = 20;
    var v = value;

    while (v > 0) {

        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;

    }

    return buf[pos..20];

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

fn str_eql(a: []const u8, b: []const u8) bool {

    return a.len == b.len and mem_eql(a, b);

}

/// Check if an entry is executable (for execve permission checks).
pub fn is_executable(slot: usize) bool {

    if (slot >= MAX_FILES) return false;
    return files[slot].permissions.can_exec;

}

/// Search the filesystem recursively for files matching a query.
/// mode 0 = name substring match, mode 1 = content substring match.
/// Writes results as null-separated absolute paths into buf.
pub fn search(start_dir: u8, query: []const u8, mode: u8, buf: [*]u8, buf_size: usize) usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    var pos: usize = 0;

    for (0..MAX_FILES) |i| {

        const f = &files[i];
        if (f.kind == .empty) continue;

        if (mode == 0) {

            // Name substring match
            if (!contains(f.name[0..f.name_len], query)) continue;

        } else {

            // Content match: skip directories and programs
            if (f.kind != .file) continue;
            if (f.size == 0) continue;

            const data: [*]const u8 = f.data orelse continue;
            if (!contains(data[0..f.size], query)) continue;

        }

        // Check that this entry is under start_dir (or start_dir is ROOT_DIR)
        if (start_dir != ROOT_DIR and !is_under_dir(@intCast(i), start_dir)) continue;

        // Build absolute path for this entry
        var path_buf: [256]u8 = undefined;
        const path_len = build_absolute_path(@intCast(i), &path_buf);

        if (path_len == 0) continue;
        if (pos + path_len + 1 > buf_size) break;

        @memcpy(buf[pos..][0..path_len], path_buf[0..path_len]);
        buf[pos + path_len] = 0;
        pos += path_len + 1;

    }

    return pos;

}

/// Check if entry is under (descendant of) a given directory.
fn is_under_dir(entry: u8, dir: u8) bool {

    var cur = entry;

    while (cur != ROOT_DIR) {

        if (cur >= MAX_FILES) return false;

        const parent = files[cur].parent;

        if (parent == dir) return true;

        cur = parent;

    }

    return false;

}

/// Build the absolute path for a file entry. Returns bytes written.
fn build_absolute_path(entry: u8, buf: *[256]u8) usize {

    if (entry >= MAX_FILES or files[entry].kind == .empty) return 0;

    var parts: [MAX_PATH_SEGMENTS][]const u8 = undefined;
    var count: usize = 0;

    var cur = entry;

    while (cur != ROOT_DIR) {

        if (cur >= MAX_FILES) return 0;
        if (count >= MAX_PATH_SEGMENTS) return 0;

        parts[count] = files[cur].name[0..files[cur].name_len];
        count += 1;
        cur = files[cur].parent;

    }

    var pos: usize = 0;
    var i = count;

    while (i > 0) {

        i -= 1;

        if (pos + 1 + parts[i].len >= 256) return 0;

        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..parts[i].len], parts[i]);
        pos += parts[i].len;

    }

    return pos;

}

/// Check if `haystack` contains `needle` as a substring.
fn contains(haystack: []const u8, needle: []const u8) bool {

    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |i| {

        if (mem_eql(haystack[i..][0..needle.len], needle)) return true;

    }

    return false;

}

// Path management

/// Add a directory to the binary search path. Returns true on success.
pub fn path_add(path: []const u8) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    if (path.len == 0 or path.len > MAX_PATH_LEN) return false;

    // Check for duplicates
    for (&search_path) |*e| {

        if (e.active and e.len == path.len and mem_eql(e.path[0..e.len], path)) return false;

    }

    for (&search_path) |*e| {

        if (!e.active) {

            @memcpy(e.path[0..path.len], path);
            e.len = path.len;
            e.active = true;
            return true;

        }

    }

    return false;

}

/// Remove a directory from the binary search path. Returns true if found.
pub fn path_remove(path: []const u8) bool {

    fs_lock.lock();
    defer fs_lock.unlock();

    for (&search_path) |*e| {

        if (e.active and e.len == path.len and mem_eql(e.path[0..e.len], path)) {

            e.active = false;
            e.len = 0;
            return true;

        }

    }

    return false;

}

/// List all path entries into buf as null-separated strings. Returns bytes written.
pub fn path_list(buf: [*]u8, buf_size: usize) usize {

    fs_lock.lock();
    defer fs_lock.unlock();

    var pos: usize = 0;

    for (&search_path) |*e| {

        if (!e.active) continue;

        if (pos + e.len + 1 > buf_size) break;

        @memcpy(buf[pos..][0..e.len], e.path[0..e.len]);
        buf[pos + e.len] = 0;
        pos += e.len + 1;

    }

    return pos;

}

/// Try to resolve a bare program name by searching the path table.
/// Returns ELF bytes if found, null otherwise.
pub fn resolve_from_path(name: []const u8) ?[]const u8 {

    fs_lock.lock();
    defer fs_lock.unlock();

    for (&search_path) |*e| {

        if (!e.active) continue;

        // Resolve the path directory
        const dir_res = resolve_existing_entry(ROOT_DIR, e.path[0..e.len]) orelse continue;
        if (files[dir_res.index].kind != .directory) continue;

        const dir_idx: u8 = @intCast(dir_res.index);

        // Look for the program in this directory
        const child = find_child_any(dir_idx, name) orelse continue;
        const entry = &files[child];

        if (entry.kind != .program) continue;
        if (!entry.permissions.can_exec) continue;
        if (entry.program_index >= embedded.programs.len) continue;

        return embedded.programs[entry.program_index].elf;

    }

    return null;

}

/// Initialize the default search path.
pub fn init_path() void {

    const default = "/programs";
    @memcpy(search_path[0].path[0..default.len], default);
    search_path[0].len = default.len;
    search_path[0].active = true;

}
