// kernel/memory/heap.zig — Kernel bump allocator backed by physical pages

const physical_allocator = @import("physical_allocator.zig");

const PAGE_SIZE: usize = 4096;

var bump_ptr: usize = 0;
var heap_end: usize = 0;

/// Carve out num_pages contiguous physical pages and use them as the initial heap.
/// The bitmap allocator always returns the lowest free page first, so sequential calls produce contiguous pages.
pub fn init(num_pages: usize) void {

    var i: usize = 0;

    while (i < num_pages) : (i += 1) {

        const page = physical_allocator.alloc_page() orelse break;

        if (i == 0) {

            bump_ptr = page;

        }

        heap_end = page + PAGE_SIZE;

    }

}

/// Allocate size bytes aligned to alignment. Returns null when the heap is exhausted.
pub fn alloc(size: usize, alignment: usize) ?[*]u8 {

    const aligned_ptr = (bump_ptr + alignment - 1) & ~(alignment - 1);

    if (aligned_ptr + size > heap_end) return null;

    bump_ptr = aligned_ptr + size;
    return @ptrFromInt(aligned_ptr);

}
