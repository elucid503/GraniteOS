// kernel/memory/heap.zig - Kernel bump allocator backed by physical pages (mutex-protected for SMP)

const physical_allocator = @import("physical_allocator.zig");
const sync = @import("../sync/mutex.zig");

const PAGE_SIZE: usize = 4096;

var bump_ptr: usize = 0;
var heap_end: usize = 0;
var heap_start: usize = 0;

var heap_lock: sync.Mutex = .{};

/// Allocates num_pages contiguous physical pages as the initial heap region.
pub fn init(num_pages: usize) void {

    var i: usize = 0;

    while (i < num_pages) : (i += 1) {

        const page = physical_allocator.alloc_page() orelse break;

        if (i == 0) {

            bump_ptr = page;
            heap_start = page;

        }

        heap_end = page + PAGE_SIZE;

    }

}

/// Allocates size bytes aligned to alignment. Returns null when the heap is exhausted.
pub fn alloc(size: usize, alignment: usize) ?[*]u8 {

    heap_lock.lock();
    defer heap_lock.unlock();

    const aligned_ptr = (bump_ptr + alignment - 1) & ~(alignment - 1);

    if (aligned_ptr + size > heap_end) return null;

    bump_ptr = aligned_ptr + size;
    return @ptrFromInt(aligned_ptr);

}

/// Returns the number of bytes currently allocated from the heap.
pub fn used_bytes() usize {

    return bump_ptr - heap_start;

}

/// Returns the total heap capacity in bytes.
pub fn capacity() usize {

    return heap_end - heap_start;

}
