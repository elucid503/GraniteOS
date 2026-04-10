// user/lib/mem.zig - User-space heap allocator built on brk()

const sys = @import("syscall.zig");

var heap_current: usize = 0;
var heap_end: usize = 0;

/// Allocate size bytes from the user heap (bump allocator over brk).
/// Returns a pointer to the allocated region, or null on failure.
pub fn alloc(size: usize, alignment: usize) ?[*]u8 {

    if (heap_current == 0) {

        heap_current = sys.brk(0);
        heap_end = heap_current;

    }

    const aligned = (heap_current + alignment - 1) & ~(alignment - 1);
    const new_end = aligned + size;

    if (new_end > heap_end) {

        // Grow in page-sized chunks

        const page_size: usize = 4096;
        const needed = ((new_end - heap_end) + page_size - 1) & ~(page_size - 1);
        const result = sys.brk(heap_end + needed);

        if (result < heap_end + needed) return null;

        heap_end = result;

    }

    heap_current = new_end;
    return @ptrFromInt(aligned);

}

/// Allocate and zero-fill size bytes.
pub fn alloc_zeroed(size: usize, alignment: usize) ?[*]u8 {

    const ptr = alloc(size, alignment) orelse return null;
    @memset(ptr[0..size], 0);

    return ptr;

}
