// kernel/process/process.zig - User process creation (ELF loader front-end)

const uart = @import("../drivers/uart.zig");
const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table_mod = @import("../memory/page_table.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const elf_loader = @import("elf_loader.zig");

const PAGE_SIZE: usize = 4096;

// User stack for inline EL0 functions (M4 path).
// Placed just below the ELF loader's stack region (0x4FF00000).
const INLINE_STACK_TOP:   usize = 0x4FE0_0000;
const INLINE_STACK_PAGES: usize = 8;

/// Run a kernel function at EL0. Allocates a dedicated page table and user stack.
/// The function must interact with the kernel exclusively via svc #0.
pub fn spawn_el0_function(entry_point: usize) void {

    const l0 = page_table_mod.create() catch return;

    for (0..INLINE_STACK_PAGES) |i| {
        const va = INLINE_STACK_TOP - (i + 1) * PAGE_SIZE;
        const pa = physical_allocator.alloc_page() orelse { page_table_mod.free(l0); return; };
        if (!page_table_mod.map_page(l0, va, pa)) { page_table_mod.free(l0); return; }
    }

    scheduler.spawn_user_task(entry_point, INLINE_STACK_TOP, 0, l0);

}

/// Load an ELF binary and spawn it as a user process.
/// Silently skips on load failure (kernel continues booting without this process).
pub fn spawn_elf(elf_bytes: []const u8) void {

    const l0 = page_table_mod.create() catch {
        uart.print("ELF spawn: page table OOM\r\n");
        return;
    };

    uart.print("DBG: switching to process table\r\n");
    // Temporarily activate this process's page table so ELF data can be written to
    // user VAs during loading. Kernel code (0x40000000) is mapped in all tables.
    page_table_mod.switch_to(l0);
    uart.print("DBG: switched, loading ELF\r\n");

    const result = elf_loader.load(elf_bytes, l0) catch |err| {
        page_table_mod.switch_to(page_table_mod.boot_root());
        page_table_mod.free(l0);
        uart.print("ELF load error: ");
        uart.print(@errorName(err));
        uart.print("\r\n");
        return;
    };

    uart.print("DBG: ELF loaded, restoring boot table\r\n");

    // Restore the boot page table before returning to kmain.
    page_table_mod.switch_to(page_table_mod.boot_root());

    uart.print("DBG: boot table restored\r\n");

    scheduler.spawn_user_task(result.entry_point, result.stack_top, result.initial_brk, l0);

}

pub const ExecResult = struct {
    entry_point: usize,
    stack_top:   usize,
    initial_brk: usize,
};

/// Replace the current process's address space with a new ELF binary.
/// Frees existing user mappings, maps and loads the new binary, updates user_brk.
/// Returns the new entry/stack/brk on success, or null on failure (process is broken).
pub fn exec_current(elf_bytes: []const u8) ?ExecResult {

    const pcb = scheduler.current_process();

    // Free user mappings, then flush TLB so stale translations are gone.
    page_table_mod.free_user_mappings(pcb.page_table_root);
    page_table_mod.switch_to(pcb.page_table_root);

    const result = elf_loader.load(elf_bytes, pcb.page_table_root) catch |err| {
        uart.print("exec failed: ");
        uart.print(@errorName(err));
        uart.print("\r\n");
        return null;
    };

    pcb.user_brk = result.initial_brk;

    return .{
        .entry_point = result.entry_point,
        .stack_top   = result.stack_top,
        .initial_brk = result.initial_brk,
    };

}
