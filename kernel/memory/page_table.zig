// kernel/memory/page_table.zig - Per-process page table management (ARM64, 4KB pages, 48-bit VA)

const physical_allocator = @import("physical_allocator.zig");

// Boot page table symbols (defined in boot/start.S, live in BSS)
extern var boot_l0_table: u8;
extern var boot_l2_table: [512]u64;

// L1[0]: 1GB device block at PA 0x0 (UART 0x09000000, GIC 0x08000000, all MMIO < 1GB)
// Matches the value written by start.S.
const DEVICE_BLOCK: u64 = 0x0060_0000_0000_0405;

// bits[1:0] = 0b11 - valid table descriptor (used for L0/L1/L2 entries pointing to sub-tables)
const TABLE_FLAGS: u64 = 0x3;

// L3 page descriptor for user pages:
//   bits[1:0]=11 (page), AttrIdx=0 (normal), AP=01 (EL0+EL1 R/W),
//   SH=11 (inner-shareable), AF=1, nG=1 (non-global, flushed by vmalle1is),
//   PXN=1 (EL1 no exec), UXN=0 (EL0 can exec)
const USER_PAGE_ATTRS: u64 = 0x0020_0000_0000_0F43;

// Number of kernel 2MB block entries at the start of the L2 table.
// L2[0..7] cover 0x40000000-0x40FFFFFF (kernel). L2[8..511] are user space.
const KERNEL_L2_ENTRIES: usize = 8;

const PAGE_SIZE: usize = 4096;

pub const Error = error{OutOfMemory};

/// Return the physical address of the boot L0 table (used by process 0 / idle task).
pub fn boot_root() usize {

    return @intFromPtr(&boot_l0_table);

}

/// Allocate a new per-process page table (L0 + L1 + L2).
/// Copies kernel L2 entries from the boot table. User entries start empty.
/// Returns the physical address of the L0 table (the value to load into TTBR0_EL1).
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

    // L0[0] -> L1
    l0_tbl[0] = l1 | TABLE_FLAGS;

    // L1[0] = 1GB device block (same as boot table)
    l1_tbl[0] = DEVICE_BLOCK;

    // L1[1] -> this process's L2
    l1_tbl[1] = l2 | TABLE_FLAGS;

    // Copy kernel 2MB block entries from boot L2 (indices 0..7)
    for (0..KERNEL_L2_ENTRIES) |i| {

        l2_tbl[i] = boot_l2_table[i];

    }

    return l0;

}

/// Map one 4KB physical page (pa) at virtual address (va) in the given page table.
/// Allocates an L3 table on demand if the 2MB region has not been used yet.
/// Returns false on OOM.
pub fn map_page(l0_pa: usize, va: usize, pa: usize) bool {

    const l1_pa = descend(l0_pa, (va >> 39) & 0x1FF) orelse return false;
    const l2_pa = descend(l1_pa, (va >> 30) & 0x1FF) orelse return false;
    const l2_tbl: [*]u64 = @ptrFromInt(l2_pa);
    const l2_idx = (va >> 21) & 0x1FF;

    // Allocate L3 table if this 2MB slot is empty
    if (l2_tbl[l2_idx] & 0x1 == 0) {

        const l3 = physical_allocator.alloc_page() orelse return false;

        @memset((@as([*]u64, @ptrFromInt(l3)))[0..512], 0);
        l2_tbl[l2_idx] = l3 | TABLE_FLAGS;

    }

    const l3_pa = table_pa(l2_tbl[l2_idx]) orelse return false;
    const l3_tbl: [*]u64 = @ptrFromInt(l3_pa);

    l3_tbl[(va >> 12) & 0x1FF] = (pa & ~@as(usize, PAGE_SIZE - 1)) | USER_PAGE_ATTRS;

    // DSB ensures the descriptor write reaches the page table walker before the VA is used
    asm volatile ("dsb ishst" ::: .{ .memory = true });

    return true;

}

/// Deep-clone a page table. For each user L2 entry, allocate a fresh L3 table;
/// for each L3 entry, allocate a new physical page and copy its contents.
/// Returns the new L0 physical address, or Error.OutOfMemory.
pub fn clone(src_l0_pa: usize) Error!usize {

    const dst_l0 = try create();
    errdefer free(dst_l0);

    // Locate source user L2 table

    const src_l0_tbl: [*]u64 = @ptrFromInt(src_l0_pa);
    const src_l1_pa = table_pa(src_l0_tbl[0]) orelse return dst_l0;
    const src_l1_tbl: [*]u64 = @ptrFromInt(src_l1_pa);
    const src_l2_pa = table_pa(src_l1_tbl[1]) orelse return dst_l0;
    const src_l2_tbl: [*]u64 = @ptrFromInt(src_l2_pa);

    // Locate destination user L2 table

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

            // Use the 48-bit PA mask: bits[47:12] only.  The naive ~0xFFF mask
            // leaves upper attribute bits (e.g. PXN at bit 53) in the address.

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

/// Unmap and free all user-space pages and L3 tables (L2[8..511]).
/// Keeps the L0/L1/L2 structure and kernel entries intact.
/// Used by exec() to wipe a process's address space before loading a new binary.
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

/// Free the entire page table and all user-mapped physical pages.
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

/// Switch the active page table to l0_pa and flush all non-global EL1 TLB entries.
pub fn switch_to(l0_pa: usize) void {

    asm volatile (
        \\dsb     ishst           // ensure all page table stores reach the walker before TTBR switch
        \\msr     ttbr0_el1, %[ttbr]
        \\isb
        \\tlbi    vmalle1is       // flush all non-global (nG=1) EL1 TLB entries
        \\dsb     ish
        \\isb
        :
        : [ttbr] "r" (l0_pa),
        : .{ .memory = true }
    );

}

/// Check whether a 4KB virtual page is already mapped in the given page table.
/// Returns true if the L3 entry for va exists and is valid.
pub fn is_page_mapped(l0_pa: usize, va: usize) bool {

    const l1_pa = descend(l0_pa, (va >> 39) & 0x1FF) orelse return false;
    const l2_pa = descend(l1_pa, (va >> 30) & 0x1FF) orelse return false;

    const l2_tbl: [*]u64 = @ptrFromInt(l2_pa);
    const l2_idx = (va >> 21) & 0x1FF;

    const l3_pa = table_pa(l2_tbl[l2_idx]) orelse return false;
    const l3_tbl: [*]u64 = @ptrFromInt(l3_pa);

    return l3_tbl[(va >> 12) & 0x1FF] & 0x1 != 0;

}

// Walk one level: return the child table's physical address, or null if the entry is not
// a valid table descriptor.
fn descend(parent_pa: usize, idx: usize) ?usize {

    const tbl: [*]u64 = @ptrFromInt(parent_pa);
    return table_pa(tbl[idx]);

}

// Extract the physical address from a valid table descriptor.
// Bits[1:0] must be 0b11 (valid + table type).
fn table_pa(entry: u64) ?usize {

    if (entry & 0x3 != TABLE_FLAGS) return null;
    return @intCast(entry & 0x0000_FFFF_FFFF_F000);

}
