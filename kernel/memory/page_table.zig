// kernel/memory/page_table.zig - Per-process page table management (ARM64, 4KB pages, 48-bit VA)

const physical_allocator = @import("physical_allocator.zig");

extern var boot_l0_table: u8; // boot page table symbols from boot/start.S
extern var boot_l2_table: [512]u64;

const DEVICE_BLOCK: u64 = 0x0060_0000_0000_0405; // 1GB device block at PA 0x0 (covers all MMIO below 1GB), matching start.S

const TABLE_FLAGS: u64 = 0x3; // bits[1:0] = 0b11 = valid table descriptor

// L3 page descriptor for user pages: page, AttrIdx=0 (normal), AP=01 (EL0+EL1 R/W), SH=11 (inner-shareable), AF=1, nG=1, PXN=1, UXN=0

const USER_PAGE_ATTRS: u64 = 0x0020_0000_0000_0F43;

const KERNEL_L2_ENTRIES: usize = 8; // L2[0..7] cover the kernel region at 0x40000000-0x40FFFFFF

const PAGE_SIZE: usize = 4096;

pub const Error = error{OutOfMemory};

/// Returns the physical address of the boot L0 table (used by process 0 / idle task).
pub fn boot_root() usize {

    return @intFromPtr(&boot_l0_table);

}

/// Allocates a new per-process L0+L1+L2 page table, copying kernel L2 entries from the boot table.
pub fn create() Error!usize {

    const l0 = physical_allocator.alloc_page() orelse return Error.OutOfMemory;
    errdefer physical_allocator.free_page(l0);

    const l1 = physical_allocator.alloc_page() orelse return Error.OutOfMemory;
    errdefer physical_allocator.free_page(l1);

    const l2 = physical_allocator.alloc_page() orelse return Error.OutOfMemory;

    const l0_tbl: [*]u64 = @ptrFromInt(l0);
    const l1_tbl: [*]u64 = @ptrFromInt(l1);
    const l2_tbl: [*]u64 = @ptrFromInt(l2);

    @memset(l0_tbl[0..512], 0);
    @memset(l1_tbl[0..512], 0);
    @memset(l2_tbl[0..512], 0);

    l0_tbl[0] = l1 | TABLE_FLAGS;
    l1_tbl[0] = DEVICE_BLOCK; // 1GB device block (same as boot table)
    l1_tbl[1] = l2 | TABLE_FLAGS;

    for (0..KERNEL_L2_ENTRIES) |i| {
        l2_tbl[i] = boot_l2_table[i];
    }

    return l0;

}

/// Maps one 4KB physical page (pa) at virtual address (va). Allocates an L3 table on demand. Returns false on OOM.
pub fn map_page(l0_pa: usize, va: usize, pa: usize) bool {

    const l1_pa = descend(l0_pa, (va >> 39) & 0x1FF) orelse return false;
    const l2_pa = descend(l1_pa, (va >> 30) & 0x1FF) orelse return false;
    const l2_tbl: [*]u64 = @ptrFromInt(l2_pa);
    const l2_idx = (va >> 21) & 0x1FF;

    if (l2_tbl[l2_idx] & 0x1 == 0) {

        const l3 = physical_allocator.alloc_page() orelse return false;

        @memset((@as([*]u64, @ptrFromInt(l3)))[0..512], 0);
        l2_tbl[l2_idx] = l3 | TABLE_FLAGS;

    }

    const l3_pa = table_pa(l2_tbl[l2_idx]) orelse return false;
    const l3_tbl: [*]u64 = @ptrFromInt(l3_pa);

    l3_tbl[(va >> 12) & 0x1FF] = (pa & ~@as(usize, PAGE_SIZE - 1)) | USER_PAGE_ATTRS;

    asm volatile ("dsb ishst" ::: .{ .memory = true }); // ensures descriptor write reaches the walker before the VA is used

    return true;

}

/// Deep-clones a page table. Allocates fresh L3 tables and physical pages, copying all user content.
pub fn clone(src_l0_pa: usize) Error!usize {

    const dst_l0 = try create();
    errdefer free(dst_l0);

    // Locate source and destination user L2 tables

    const src_l0_tbl: [*]u64 = @ptrFromInt(src_l0_pa);
    const src_l1_pa = table_pa(src_l0_tbl[0]) orelse return dst_l0;
    const src_l1_tbl: [*]u64 = @ptrFromInt(src_l1_pa);
    const src_l2_pa = table_pa(src_l1_tbl[1]) orelse return dst_l0;
    const src_l2_tbl: [*]u64 = @ptrFromInt(src_l2_pa);

    const dst_l0_tbl: [*]u64 = @ptrFromInt(dst_l0);
    const dst_l1_pa = table_pa(dst_l0_tbl[0]) orelse return dst_l0;
    const dst_l1_tbl: [*]u64 = @ptrFromInt(dst_l1_pa);
    const dst_l2_pa = table_pa(dst_l1_tbl[1]) orelse return dst_l0;
    const dst_l2_tbl: [*]u64 = @ptrFromInt(dst_l2_pa);

    for (KERNEL_L2_ENTRIES..512) |l2i| {

        const src_l3_pa = table_pa(src_l2_tbl[l2i]) orelse continue;
        const src_l3: [*]u64 = @ptrFromInt(src_l3_pa);

        const dst_l3_pa = physical_allocator.alloc_page() orelse return Error.OutOfMemory;

        @memset((@as([*]u64, @ptrFromInt(dst_l3_pa)))[0..512], 0);
        dst_l2_tbl[l2i] = dst_l3_pa | TABLE_FLAGS;

        const dst_l3: [*]u64 = @ptrFromInt(dst_l3_pa);

        for (0..512) |l3i| {

            const src_entry = src_l3[l3i];
            if (src_entry & 0x1 == 0) continue;

            // Use 48-bit PA mask: bits[47:12] only — naive ~0xFFF leaves upper attribute bits in the address
            const src_phys: usize = @intCast(src_entry & 0x0000_FFFF_FFFF_F000);

            const dst_phys = physical_allocator.alloc_page() orelse return Error.OutOfMemory;
            const src_bytes: [*]const u8 = @ptrFromInt(src_phys);
            const dst_bytes: [*]u8 = @ptrFromInt(dst_phys);

            @memcpy(dst_bytes[0..PAGE_SIZE], src_bytes[0..PAGE_SIZE]);

            dst_l3[l3i] = dst_phys | USER_PAGE_ATTRS;

        }

    }

    return dst_l0;

}

/// Frees all user-space pages and L3 tables (L2[8..511]). Keeps the L0/L1/L2 structure and kernel entries.
pub fn free_user_mappings(l0_pa: usize) void {

    const l0_tbl: [*]u64 = @ptrFromInt(l0_pa);

    const l1_pa = table_pa(l0_tbl[0]) orelse return;
    const l1_tbl: [*]u64 = @ptrFromInt(l1_pa);

    const l2_pa = table_pa(l1_tbl[1]) orelse return;
    const l2_tbl: [*]u64 = @ptrFromInt(l2_pa);

    for (KERNEL_L2_ENTRIES..512) |l2i| {

        const l3_pa = table_pa(l2_tbl[l2i]) orelse continue;
        const l3_tbl: [*]u64 = @ptrFromInt(l3_pa);

        for (0..512) |l3i| {

            const entry = l3_tbl[l3i];
            if (entry & 0x1 == 0) continue;

            physical_allocator.free_page(@intCast(entry & 0x0000_FFFF_FFFF_F000));

        }

        physical_allocator.free_page(l3_pa);
        l2_tbl[l2i] = 0;

    }

}

/// Frees the entire page table and all user-mapped physical pages.
pub fn free(l0_pa: usize) void {

    const l0_tbl: [*]u64 = @ptrFromInt(l0_pa);

    if (table_pa(l0_tbl[0])) |l1_pa| {

        const l1_tbl: [*]u64 = @ptrFromInt(l1_pa);

        if (table_pa(l1_tbl[1])) |l2_pa| {

            free_user_mappings(l0_pa);
            physical_allocator.free_page(l2_pa);

        }

        physical_allocator.free_page(l1_pa);

    }

    physical_allocator.free_page(l0_pa);

}

/// Switches the active page table to l0_pa and flushes all non-global EL1 TLB entries.
pub fn switch_to(l0_pa: usize) void {

    asm volatile (

        \\dsb     ishst
        \\msr     ttbr0_el1, %[ttbr]
        \\isb
        \\tlbi    vmalle1is
        \\dsb     ish
        \\isb
        :
        : [ttbr] "r" (l0_pa),
        : .{ .memory = true }

    );

}

/// Returns true if the L3 entry for va exists and is valid in the given page table.
pub fn is_page_mapped(l0_pa: usize, va: usize) bool {

    const l1_pa = descend(l0_pa, (va >> 39) & 0x1FF) orelse return false;
    const l2_pa = descend(l1_pa, (va >> 30) & 0x1FF) orelse return false;

    const l2_tbl: [*]u64 = @ptrFromInt(l2_pa);
    const l2_idx = (va >> 21) & 0x1FF;

    const l3_pa = table_pa(l2_tbl[l2_idx]) orelse return false;
    const l3_tbl: [*]u64 = @ptrFromInt(l3_pa);

    return l3_tbl[(va >> 12) & 0x1FF] & 0x1 != 0;

}

fn descend(parent_pa: usize, idx: usize) ?usize {

    const tbl: [*]u64 = @ptrFromInt(parent_pa);
    return table_pa(tbl[idx]);

}

fn table_pa(entry: u64) ?usize {

    if (entry & 0x3 != TABLE_FLAGS) return null;
    return @intCast(entry & 0x0000_FFFF_FFFF_F000);

}
