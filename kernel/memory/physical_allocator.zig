// kernel/memory/physical_allocator.zig — Bitmap physical page allocator over available RAM

const PAGE_SIZE: usize = 4096;
const RAM_BASE: usize = 0x4000_0000;
const RAM_END: usize = 0x5000_0000; // 256MB at 0x40000000
const TOTAL_PAGES: usize = (RAM_END - RAM_BASE) / PAGE_SIZE; // 65536

// Provided by linker.ld — first address not occupied by the kernel image + stack
extern const __kernel_end: u8;

// One bit per physical page: 1 = used, 0 = free
var bitmap: [TOTAL_PAGES / 8]u8 = undefined;

pub var free_page_count: usize = 0;

/// Mark all pages at and above the end of the kernel image as free.
pub fn init() void {

    @memset(&bitmap, 0xFF); // Start with every page marked used

    const kernel_end_addr = @intFromPtr(&__kernel_end);
    const first_free_addr = align_up(kernel_end_addr, PAGE_SIZE);
    const first_free_idx  = (first_free_addr - RAM_BASE) / PAGE_SIZE;

    // Release every page above the kernel to the free pool
    for (first_free_idx..TOTAL_PAGES) |i| {

        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
        bitmap[i / 8] &= ~bit;
        free_page_count += 1;

    }

}

/// Allocate one 4KB physical page. Returns the page's physical address or null if OOM.
pub fn alloc_page() ?usize {

    for (0..TOTAL_PAGES) |i| {

        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));

        if (bitmap[i / 8] & bit == 0) {

            bitmap[i / 8] |= bit;
            free_page_count -= 1;
            return RAM_BASE + i * PAGE_SIZE;

        }

    }

    return null;

}

/// Return a previously allocated page to the free pool.
pub fn free_page(page_addr: usize) void {

    const i   = (page_addr - RAM_BASE) / PAGE_SIZE;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
    bitmap[i / 8] &= ~bit;
    free_page_count += 1;

}

fn align_up(addr: usize, alignment: usize) usize {

    return (addr + alignment - 1) & ~(alignment - 1);

}
