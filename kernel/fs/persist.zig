// kernel/fs/persist.zig - Persistent FS: superblock at sector 0, one entry header per slot (sectors 1-64), file data at sectors 65+ (8 sectors / 4KB per file)

const fs = @import("fs.zig");
const extio = @import("../drivers/extio.zig");

const MAGIC: u32 = 0x474E4954; // "GNIT" (GraNITe)
const VERSION: u32 = 1;

const HEADER_SECTOR: u64 = 0;
const ENTRY_SECTOR_BASE: u64 = 1;
const DATA_SECTOR_BASE: u64 = 65;
const SECTORS_PER_FILE: u64 = 8;

const SECTOR_SIZE: usize = 512;

// On-disk file entry header (512 bytes, packed to fit one sector)
const DiskEntry = extern struct {

    name: [fs.MAX_NAME + 1]u8,
    name_len: u8,
    parent: u8,
    kind: u8, // 0=empty, 1=file, 2=directory, 3=program (skipped on load)
    owner_lo: u16,
    owner_hi: u16,
    size_lo: u16,
    size_hi: u16,
    permissions: u8, // bit0=can_read, bit1=can_write, bit2=can_exec, bit3=can_delete
    _pad: [512 - 32 - 1 - 1 - 1 - 2 - 2 - 2 - 2 - 1]u8,

};

const KIND_EMPTY: u8 = 0;
const KIND_FILE: u8 = 1;
const KIND_DIR: u8 = 2;
const KIND_PROGRAM: u8 = 3;

/// Loads the persistent FS from disk. Returns true if a valid superblock was found.
pub fn load() bool {

    if (!extio.is_available()) return false;

    var sb_buf: [SECTOR_SIZE]u8 align(16) = undefined;

    if (!extio.read_sector(HEADER_SECTOR, &sb_buf)) return false;

    const magic = read_u32(&sb_buf, 0);
    const version = read_u32(&sb_buf, 4);

    if (magic != MAGIC or version != VERSION) return false;

    var sector_buf: [SECTOR_SIZE]u8 align(16) = undefined;

    for (0..fs.MAX_FILES) |i| {

        if (!extio.read_sector(ENTRY_SECTOR_BASE + @as(u64, @intCast(i)), &sector_buf)) continue;

        const disk: *const DiskEntry = @ptrCast(@alignCast(&sector_buf));

        if (disk.kind == KIND_EMPTY or disk.kind == KIND_PROGRAM) continue;

        const entry = &fs.files[i];

        entry.name = disk.name;
        entry.name_len = disk.name_len;
        entry.parent = disk.parent;
        entry.owner = @as(u32, disk.owner_hi) << 16 | @as(u32, disk.owner_lo);

        const size: usize = @as(usize, disk.size_hi) << 16 | @as(usize, disk.size_lo);

        entry.permissions = .{

            .can_read = disk.permissions & 1 != 0,
            .can_write = disk.permissions & 2 != 0,
            .can_exec = disk.permissions & 4 != 0,
            .can_delete = disk.permissions & 8 != 0,

        };

        if (disk.kind == KIND_DIR) {

            entry.kind = .directory;
            entry.size = 0;
            entry.capacity = 0;
            entry.data = null;

        } else if (disk.kind == KIND_FILE) {

            entry.kind = .file;

            if (entry.data == null) {

                const heap = @import("../memory/heap.zig");
                entry.data = heap.alloc(fs.FILE_CAPACITY, 8);
                entry.capacity = if (entry.data != null) fs.FILE_CAPACITY else 0;

            }

            entry.size = @min(size, entry.capacity);

            if (entry.data) |data| {

                var data_buf: [SECTOR_SIZE]u8 align(16) = undefined;
                var offset: usize = 0;

                for (0..SECTORS_PER_FILE) |s| {

                    if (offset >= entry.size) break;

                    const sector = DATA_SECTOR_BASE + @as(u64, @intCast(i)) * SECTORS_PER_FILE + @as(u64, @intCast(s));

                    if (extio.read_sector(sector, &data_buf)) {

                        const to_copy = @min(SECTOR_SIZE, entry.size - offset);
                        @memcpy(data[offset..][0..to_copy], data_buf[0..to_copy]);
                        offset += to_copy;

                    }

                }

            }

        }

    }

    return true;

}

/// Writes the superblock and all file entries to disk.
pub fn save_all() void {

    if (!extio.is_available()) return;

    var sb_buf: [SECTOR_SIZE]u8 align(16) = [_]u8{0} ** SECTOR_SIZE;

    write_u32(&sb_buf, 0, MAGIC);
    write_u32(&sb_buf, 4, VERSION);
    write_u32(&sb_buf, 8, fs.MAX_FILES);

    _ = extio.write_sector(HEADER_SECTOR, &sb_buf);

    for (0..fs.MAX_FILES) |i| {

        save_entry(i);

    }

}

/// Writes a single file entry and its data to disk.
pub fn save_entry(index: usize) void {

    if (!extio.is_available()) return;
    if (index >= fs.MAX_FILES) return;

    const entry = &fs.files[index];

    var buf: [SECTOR_SIZE]u8 align(16) = [_]u8{0} ** SECTOR_SIZE;
    const disk: *DiskEntry = @ptrCast(@alignCast(&buf));

    disk.name = entry.name;
    disk.name_len = entry.name_len;
    disk.parent = entry.parent;
    disk.owner_lo = @truncate(entry.owner);
    disk.owner_hi = @truncate(entry.owner >> 16);
    disk.size_lo = @truncate(entry.size);
    disk.size_hi = @truncate(entry.size >> 16);

    disk.permissions = @as(u8, if (entry.permissions.can_read) @as(u8, 1) else 0) |
        @as(u8, if (entry.permissions.can_write) @as(u8, 2) else 0) |
        @as(u8, if (entry.permissions.can_exec) @as(u8, 4) else 0) |
        @as(u8, if (entry.permissions.can_delete) @as(u8, 8) else 0);

    switch (entry.kind) {

        .empty => disk.kind = KIND_EMPTY,
        .file => disk.kind = KIND_FILE,
        .directory => disk.kind = KIND_DIR,
        .program => disk.kind = KIND_PROGRAM,

    }

    _ = extio.write_sector(ENTRY_SECTOR_BASE + @as(u64, @intCast(index)), &buf);

    if (entry.kind == .file and entry.size > 0) {

        if (entry.data) |data| {

            var offset: usize = 0;

            for (0..SECTORS_PER_FILE) |s| {

                if (offset >= entry.size) break;

                var data_buf: [SECTOR_SIZE]u8 align(16) = [_]u8{0} ** SECTOR_SIZE;
                const to_copy = @min(SECTOR_SIZE, entry.size - offset);

                @memcpy(data_buf[0..to_copy], data[offset..][0..to_copy]);

                const sector = DATA_SECTOR_BASE + @as(u64, @intCast(index)) * SECTORS_PER_FILE + @as(u64, @intCast(s));
                _ = extio.write_sector(sector, &data_buf);

                offset += SECTOR_SIZE;

            }

        }

    }

}

/// Zeroes the superblock and all entry sectors. On next boot, the magic check fails and the FS starts fresh.
pub fn format() void {

    if (!extio.is_available()) return;

    var buf: [SECTOR_SIZE]u8 align(16) = [_]u8{0} ** SECTOR_SIZE;

    _ = extio.write_sector(HEADER_SECTOR, &buf);

    for (0..fs.MAX_FILES) |i| {
        _ = extio.write_sector(ENTRY_SECTOR_BASE + @as(u64, @intCast(i)), &buf);
    }

}

fn read_u32(buf: []const u8, offset: usize) u32 {

    return @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);

}

fn write_u32(buf: []u8, offset: usize, val: u32) void {

    buf[offset] = @truncate(val);
    buf[offset + 1] = @truncate(val >> 8);
    buf[offset + 2] = @truncate(val >> 16);
    buf[offset + 3] = @truncate(val >> 24);

}
