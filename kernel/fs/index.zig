// kernel/fs/index.zig — Flat sorted index for fast filesystem lookups
//
// Maintains a sorted array of (name_hash, slot) pairs across the entire
// directory hierarchy. Marked dirty on any FS mutation; rebuilt lazily
// on the next lookup. Binary search gives O(log n) exact-name lookups
// without walking the directory tree.

const fs = @import("fs.zig");

const IndexEntry = struct {

    hash: u32,
    slot: u8,

};

var entries: [fs.MAX_FILES]IndexEntry = undefined;
var count: usize = 0;
var dirty: bool = true;

/// Mark the index as stale. Called after any FS mutation.
pub fn invalidate() void {

    dirty = true;

}

/// Rebuild the index from the current file table if stale.
pub fn rebuild() void {

    if (!dirty) return;

    count = 0;

    for (0..fs.MAX_FILES) |i| {

        if (fs.files[i].kind == .empty) continue;

        entries[count] = .{

            .hash = fnv1a(fs.files[i].name[0..fs.files[i].name_len]),
            .slot = @intCast(i),

        };

        count += 1;

    }

    // Insertion sort (n <= 64, fast enough)
    var i: usize = 1;

    while (i < count) : (i += 1) {

        const key = entries[i];
        var j: usize = i;

        while (j > 0 and entries[j - 1].hash > key.hash) {

            entries[j] = entries[j - 1];
            j -= 1;

        }

        entries[j] = key;

    }

    dirty = false;

}

/// Find all file slots whose name exactly matches `name`.
/// Returns matching slot indices via the callback buffer (max 8 results).
pub fn lookup_exact(name: []const u8, results: *[8]u8) usize {

    rebuild();

    const target = fnv1a(name);
    var found: usize = 0;

    // Binary search to first candidate
    var lo: usize = 0;
    var hi: usize = count;

    while (lo < hi) {

        const mid = lo + (hi - lo) / 2;

        if (entries[mid].hash < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }

    }

    // Scan all entries with matching hash (collisions possible)
    while (lo < count and entries[lo].hash == target and found < 8) {

        const slot = entries[lo].slot;
        const f = &fs.files[slot];

        if (f.name_len == name.len and fs_mem_eql(f.name[0..f.name_len], name)) {

            results[found] = slot;
            found += 1;

        }

        lo += 1;

    }

    return found;

}

/// FNV-1a hash for short strings.
fn fnv1a(data: []const u8) u32 {

    var h: u32 = 0x811c9dc5;

    for (data) |b| {

        h ^= b;
        h *%= 0x01000193;

    }

    return h;

}

fn fs_mem_eql(a: []const u8, b: []const u8) bool {

    if (a.len != b.len) return false;

    for (a, b) |x, y| {

        if (x != y) return false;

    }

    return true;

}
