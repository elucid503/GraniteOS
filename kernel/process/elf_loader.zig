// kernel/process/elf_loader.zig - ELF64 AArch64 binary loader (per-process page tables)

const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table = @import("../memory/page_table.zig");

const PAGE_SIZE: usize = 4096;

// User stack: 32KB immediately below 0x4FF00000, growing downward.
const USER_STACK_PAGES: usize = 8;
const USER_STACK_TOP: usize   = 0x4FF0_0000;

const ELF_MAGIC:   u32 = 0x464C457F; // "\x7FELF" little-endian
const ELFCLASS64:  u8  = 2;
const ELFDATA2LSB: u8  = 1;
const ET_EXEC:     u16 = 2;
const EM_AARCH64:  u16 = 183;
const PT_LOAD:     u32 = 1;

const ElfHeader = extern struct {
    e_ident_magic:   u32,
    e_ident_class:   u8,
    e_ident_data:    u8,
    e_ident_version: u8,
    e_ident_os_abi:  u8,
    e_ident_pad:     [8]u8,
    e_type:          u16,
    e_machine:       u16,
    e_version:       u32,
    e_entry:         u64,
    e_phoff:         u64,
    e_shoff:         u64,
    e_flags:         u32,
    e_ehsize:        u16,
    e_phentsize:     u16,
    e_phnum:         u16,
    e_shentsize:     u16,
    e_shnum:         u16,
    e_shstrndx:      u16,
};

const ProgramHeader = extern struct {
    p_type:   u32,
    p_flags:  u32,
    p_offset: u64,
    p_vaddr:  u64,
    p_paddr:  u64,
    p_filesz: u64,
    p_memsz:  u64,
    p_align:  u64,
};

pub const LoadResult = struct {
    entry_point: usize,
    stack_top:   usize,
    initial_brk: usize, // first byte past the last loaded segment (page-aligned)
};

pub const LoadError = error{
    BadMagic,
    NotAArch64,
    NotExecutable,
    OutOfMemory,
};

/// Validate the ELF, map pages into l0_pa, copy segments, allocate user stack.
/// TTBR0_EL1 must already point to l0_pa so user VAs are writable.
pub fn load(elf_bytes: []const u8, l0_pa: usize) LoadError!LoadResult {

    if (elf_bytes.len < @sizeOf(ElfHeader)) return LoadError.BadMagic;

    // Use align(1) to avoid a runtime alignment fault when the embedded ELF bytes
    // are not naturally aligned to ElfHeader's alignment (8 bytes for u64 fields).
    const hdr: *align(1) const ElfHeader = @ptrCast(elf_bytes.ptr);

    if (hdr.e_ident_magic != ELF_MAGIC)   return LoadError.BadMagic;
    if (hdr.e_ident_class != ELFCLASS64)  return LoadError.BadMagic;
    if (hdr.e_ident_data  != ELFDATA2LSB) return LoadError.BadMagic;
    if (hdr.e_type        != ET_EXEC)     return LoadError.NotExecutable;
    if (hdr.e_machine     != EM_AARCH64)  return LoadError.NotAArch64;

    var max_loaded_addr: usize = 0;

    const ph_base = elf_bytes.ptr + hdr.e_phoff;

    for (0..hdr.e_phnum) |i| {

        const ph: *align(1) const ProgramHeader = @ptrCast(
            ph_base + i * hdr.e_phentsize,
        );

        if (ph.p_type != PT_LOAD) continue;

        try load_segment(elf_bytes, ph, l0_pa);

        const seg_end: usize = @intCast(ph.p_vaddr + ph.p_memsz);
        if (seg_end > max_loaded_addr) max_loaded_addr = seg_end;

    }

    const initial_brk = align_up(max_loaded_addr, PAGE_SIZE);

    try alloc_user_stack(l0_pa);

    return .{
        .entry_point = @intCast(hdr.e_entry),
        .stack_top   = USER_STACK_TOP,
        .initial_brk = initial_brk,
    };

}

fn load_segment(elf_bytes: []const u8, ph: *align(1) const ProgramHeader, l0_pa: usize) LoadError!void {

    const va_start: usize = @intCast(ph.p_vaddr);
    const va_end:   usize = @intCast(ph.p_vaddr + ph.p_memsz);

    const page_start = va_start & ~@as(usize, PAGE_SIZE - 1);
    const page_end   = align_up(va_end, PAGE_SIZE);

    // Allocate physical pages and map them at the segment's virtual addresses.
    var va = page_start;
    while (va < page_end) : (va += PAGE_SIZE) {
        const pa = physical_allocator.alloc_page() orelse return LoadError.OutOfMemory;
        if (!page_table.map_page(l0_pa, va, pa)) return LoadError.OutOfMemory;
    }

    // ISB ensures the new TLB entries (from map_page DSB) are visible before we write.
    asm volatile ("isb" ::: .{ .memory = true });

    // Zero the full virtual extent, then copy file image in.
    const mem: [*]u8 = @ptrFromInt(va_start);
    @memset(mem[0..@intCast(ph.p_memsz)], 0);

    if (ph.p_filesz > 0) {
        const offset: usize = @intCast(ph.p_offset);
        const filesz: usize = @intCast(ph.p_filesz);
        @memcpy(mem[0..filesz], elf_bytes[offset .. offset + filesz]);
    }

    // Clean D-cache to Point of Unification so the I-cache sees the written code.
    // Required any time the kernel writes code pages that will be executed later.
    const CACHE_LINE_SIZE: usize = 64;
    var cache_va = page_start;
    while (cache_va < page_end) : (cache_va += CACHE_LINE_SIZE) {
        asm volatile ("dc cvau, %[va]" :: [va] "r" (cache_va) : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });

    cache_va = page_start;
    while (cache_va < page_end) : (cache_va += CACHE_LINE_SIZE) {
        asm volatile ("ic ivau, %[va]" :: [va] "r" (cache_va) : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });

}

fn alloc_user_stack(l0_pa: usize) LoadError!void {

    for (0..USER_STACK_PAGES) |i| {
        const va = USER_STACK_TOP - (i + 1) * PAGE_SIZE;
        const pa = physical_allocator.alloc_page() orelse return LoadError.OutOfMemory;
        if (!page_table.map_page(l0_pa, va, pa)) return LoadError.OutOfMemory;
    }

}

fn align_up(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}
