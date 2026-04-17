// kernel/process/process.zig - User process creation (ELF loader front-end)

const uart = @import("../drivers/uart.zig");
const physical_allocator = @import("../memory/physical_allocator.zig");
const page_table = @import("../memory/page_table.zig");
const scheduler = @import("../scheduler/scheduler.zig");
const elf_loader = @import("elf_loader.zig");

const PAGE_SIZE: usize = 4096;

const INLINE_STACK_TOP: usize = 0x4FE0_0000; // just below the ELF loader's stack region (0x4FF00000)
const INLINE_STACK_PAGES: usize = 8;

/// Runs a kernel function at EL0. Allocates a dedicated page table and user stack.
pub fn spawn_el0_function(entry_point: usize) void {

    const l0 = page_table.create() catch return;

    for (0..INLINE_STACK_PAGES) |i| {

        const va = INLINE_STACK_TOP - (i + 1) * PAGE_SIZE;

        const pa = physical_allocator.alloc_page() orelse { page_table.free(l0); return; };
        if (!page_table.map_page(l0, va, pa)) { page_table.free(l0); return; }

    }

    scheduler.spawn_user_task(entry_point, INLINE_STACK_TOP, 0, l0);

}

/// Loads an ELF binary and spawns it as a user process. Silently skips on load failure.
pub fn spawn_elf(elf_bytes: []const u8) void {

    const l0 = page_table.create() catch {

        uart.print("ELF spawn: page table OOM\r\n");
        return;

    };

    // Temporarily activate this process's page table so ELF data can be written to user VAs
    page_table.switch_to(l0);

    const result = elf_loader.load(elf_bytes, l0) catch |err| {

        page_table.switch_to(page_table.boot_root());
        page_table.free(l0);

        uart.print("ELF load error: ");
        uart.print(@errorName(err));
        uart.print("\r\n");

        return;

    };

    page_table.switch_to(page_table.boot_root());

    scheduler.spawn_user_task(result.entry_point, result.stack_top, result.initial_brk, l0);

}

pub const ExecResult = struct {

    entry_point: usize,
    stack_top: usize,
    initial_brk: usize,

};

/// Replaces the current process's address space with a new ELF binary. Returns entry/stack/brk on success, null on failure.
pub fn exec_current(elf_bytes: []const u8) ?ExecResult {

    const pcb = scheduler.current_process();

    page_table.free_user_mappings(pcb.page_table_root);
    page_table.switch_to(pcb.page_table_root);

    const result = elf_loader.load(elf_bytes, pcb.page_table_root) catch |err| {

        uart.print("exec failed: ");
        uart.print(@errorName(err));
        uart.print("\r\n");

        return null;

    };

    pcb.user_brk = result.initial_brk;

    return .{

        .entry_point = result.entry_point,
        .stack_top = result.stack_top,
        .initial_brk = result.initial_brk,

    };

}
