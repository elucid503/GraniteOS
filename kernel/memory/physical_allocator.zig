// kernel/memory/physical_allocator.zig - Bitmap page allocator over 256MB RAM at 0x40000000 (mutex-protected for SMP)

const sync = @import("../sync/mutex.zig");

const PAGE_SIZE: usize = 4096;
const RAM_BASE: usize = 0x4000_0000;
const RAM_END: usize = 0x5000_0000;
pub const TOTAL_PAGES: usize = (RAM_END - RAM_BASE) / PAGE_SIZE; // 65536

extern const __kernel_end: u8; // first address past the kernel image + stack (from linker.ld)

var bitmap: [TOTAL_PAGES / 8]u8 = undefined; // 1 bit per page: 1 = used, 0 = free

pub var free_page_count: usize = 0;

var alloc_lock: sync.Mutex = .{};

/// Marks all pages above the end of the kernel image as free.
pub fn init() void {

    @memset(&bitmap, 0xFF); // start with every page marked used

    const kernel_end_addr = @intFromPtr(&__kernel_end);
    const first_free_addr = align_up(kernel_end_addr, PAGE_SIZE);
    const first_free_idx = (first_free_addr - RAM_BASE) / PAGE_SIZE;

    for (first_free_idx..TOTAL_PAGES) |i| {

        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
        bitmap[i / 8] &= ~bit;
        free_page_count += 1;

    }

}

/// Allocates one 4KB physical page. Returns its physical address, or null if OOM.
pub fn alloc_page() ?usize {

    alloc_lock.lock();
    defer alloc_lock.unlock();

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

/// Allocates the specific page at addr. Returns addr on success, null if out of range or already used.
pub fn alloc_page_at(addr: usize) ?usize {

    if (addr < RAM_BASE or addr >= RAM_END) return null;

    alloc_lock.lock();
    defer alloc_lock.unlock();

    const i = (addr - RAM_BASE) / PAGE_SIZE;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));

    if (bitmap[i / 8] & bit != 0) return null; // already allocated

    bitmap[i / 8] |= bit;
    free_page_count -= 1;
    return addr;

}

/// Returns a previously allocated page to the free pool.
pub fn free_page(page_addr: usize) void {

    alloc_lock.lock();
    defer alloc_lock.unlock();

    const i = (page_addr - RAM_BASE) / PAGE_SIZE;
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
    bitmap[i / 8] &= ~bit;
    free_page_count += 1;

}

fn align_up(addr: usize, alignment: usize) usize {

    return (addr + alignment - 1) & ~(alignment - 1);

}
