// boot/start.S - ARM64 bootloader: SMP boot, EL2->EL1 drop, BSS zero, jump to kmain
//
// Core 0: full init (BSS zero, page tables, MMU, kmain).
// Cores 1-3: wait on a mailbox, then jump to the secondary entry point
// written by core 0 after kernel init completes.

.section ".text.boot"
.global _start

_start:

    // Read core ID (Aff0 field of MPIDR_EL1[7:0])

    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF

    // Cores 1-3 go to the secondary entry (dead path with PSCI, kept for safety)
    cbnz    x0, secondary_entry

    // ---- Core 0 only from here ----

    // Drop from EL2 to EL1 if needed; skip if already at EL1

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    bne     .Lel1_already

    // HCR_EL2: RW bit (31) - EL1 runs AArch64, not AArch32

    mov     x0, #(1 << 31)
    msr     hcr_el2, x0

    // SCTLR_EL1: safe reset value - MMU off, caches off, little-endian

    mov     x0, #0x0800
    movk    x0, #0x30d0, lsl #16
    msr     sctlr_el1, x0

    // SPSR_EL2: EL1h (0b00101), all interrupts masked

    mov     x0, #(0b00101)
    orr     x0, x0, #(0xF << 6)
    msr     spsr_el2, x0

    // ELR_EL2: eret drops to EL1 and branches here

    adr     x0, .Lel1_already
    msr     elr_el2, x0
    eret


.Lel1_already:

    // Set stack pointer to top of linker-defined kernel stack region

    ldr     x0, =__stack_top
    mov     sp, x0

    // Zero BSS (8 bytes per iteration via xzr; linker provides __bss_start/__bss_end)

    ldr     x0, =__bss_start
    ldr     x1, =__bss_end

.Lbss_loop:

    cmp     x0, x1
    bge     .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop

.Lbss_done:

    // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11) - Zig may emit NEON instructions

    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0

    // Install exception vector table (VBAR_EL1)

    ldr     x0, =exception_vectors
    msr     vbar_el1, x0
    isb

    // Configure memory attributes:
    //   Attr0 = 0xFF = Normal memory (inner+outer write-back, read/write allocate)
    //   Attr1 = 0x00 = Device-nGnRnE (strongly ordered, no reordering or speculation)

    mov     x0, #0xff
    msr     mair_el1, x0

    // Configure translation control:
    //   T0SZ=16, T1SZ=16 - 48-bit VA space
    //   4KB granule (TG0=0b00, TG1=0b10), inner-shareable WB caches
    //   IPS=0b001 (36-bit physical address)
    //   EPD1=1 - disable TTBR1 walks; high-half faults until kernel migrates

    ldr     x0, =0x1B5183510
    msr     tcr_el1, x0
    isb

    // Build two-level boot page table: L0 -> L1 (both table descriptors),
    // L1[0] = 1GB device block, L1[1] -> L2 table.
    // L2 splits the normal-memory GB into 2MB blocks with per-region permissions.

    // L0[0] -> L1 table

    ldr     x0, =boot_l0_table
    ldr     x1, =boot_l1_table
    orr     x1, x1, #0x3           // table descriptor: valid=1, type=table
    str     x1, [x0]

    // L1[0] = 1GB device-memory block at PA 0x0
    //   Covers UART (0x09000000), GIC (0x08000000), and all MMIO below 1GB
    //   PXN=1, UXN=1, AF=1, SH=non-shareable, AttrIdx=1 (device), block

    ldr     x0, =boot_l1_table
    ldr     x1, =0x0060000000000405
    str     x1, [x0]

    // L1[1] -> L2 table (splits 0x40000000-0x7FFFFFFF at 2MB granularity)

    ldr     x1, =boot_l2_table
    orr     x1, x1, #0x3           // table descriptor
    str     x1, [x0, #8]

    // Fill boot_l2_table.
    // Each entry covers 2MB; 512 entries cover the full 1GB (0x40000000-0x7FFFFFFF).
    //
    // L2[0..7]   (0x40000000-0x40FFFFFF, 16MB) - kernel memory
    //   UXN=1 (EL0 no execute), PXN=0 (EL1 execute OK), AP=00 (EL1 data only)
    //   attr bits: 0x0040000000000701  (UXN=bit54, AP=00, AF, SH=inner, AttrIdx=0, block)
    //
    // L2[8..511] (0x41000000-0x7FFFFFFF) - user memory
    //   UXN=0 (EL0 execute OK), PXN=1 (EL1 no execute), AP=01 (EL0+EL1 R/W)
    //   attr bits: 0x0020000000000741  (PXN=bit53, AP=01, AF, SH=inner, AttrIdx=0, block)

    ldr     x0, =boot_l2_table
    mov     x1, #0x40000000         // current PA (2MB-aligned, advances in loop)

    // Kernel entries: L2[0..7]

    ldr     x2, =0x0040000000000701 // UXN=1, PXN=0, AP=00
    mov     x3, #0                  // entry index
    mov     x4, #8

.Lkernel_l2_loop:

    orr     x5, x1, x2
    str     x5, [x0, x3, lsl #3]
    add     x1, x1, #0x200000       // PA += 2MB
    add     x3, x3, #1
    cmp     x3, x4
    b.lt    .Lkernel_l2_loop

    // User entries: L2[8..511]
    // nG=1 (bit 11) so vmalle1is flushes these entries when switching to per-process tables

    ldr     x2, =0x0020000000000F41 // UXN=0, PXN=1, AP=01, nG=1
    mov     x4, #512

.Luser_l2_loop:

    orr     x5, x1, x2
    str     x5, [x0, x3, lsl #3]
    add     x1, x1, #0x200000       // PA += 2MB
    add     x3, x3, #1
    cmp     x3, x4
    b.lt    .Luser_l2_loop

    // Ensure all page table stores reach memory before the table walker sees them

    dsb     sy

    // Point TTBR0 at the L0 table; zero TTBR1 (EPD1 above ensures no walk)

    ldr     x0, =boot_l0_table
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, xzr
    isb

    // Enable MMU (M=1), data cache (C=1), and instruction cache (I=1)

    mrs     x0, sctlr_el1
    orr     x0, x0, #(1 << 0)      // M: enable MMU
    orr     x0, x0, #(1 << 2)      // C: enable data cache
    orr     x0, x0, #(1 << 12)     // I: enable instruction cache
    msr     sctlr_el1, x0
    isb                             // pipeline flush - MMU is now active

    bl      kmain


// ---- Secondary core entry (cores 1-3) ----
// Entry point for PSCI CPU_ON. Starts at EL1 with MMU off.
// Also handles EL2 entry for non-PSCI platforms.

.global secondary_entry
secondary_entry:

    // Read core ID from MPIDR_EL1.Aff0

    mrs     x19, mpidr_el1
    and     x19, x19, #0xFF

    // Drop from EL2 to EL1 if needed (PSCI starts at EL1; handle both cases)

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    bne     .Lsec_el1

    mov     x0, #(1 << 31)
    msr     hcr_el2, x0

    mov     x0, #0x0800
    movk    x0, #0x30d0, lsl #16
    msr     sctlr_el1, x0

    mov     x0, #(0b00101)
    orr     x0, x0, #(0xF << 6)
    msr     spsr_el2, x0

    adr     x0, .Lsec_el1
    msr     elr_el2, x0
    eret

.Lsec_el1:

    // Set SCTLR_EL1 to a known-good state (MMU off, caches off).
    // Needed for the PSCI path which skips the EL2 drop.

    mov     x0, #0x0800
    movk    x0, #0x30d0, lsl #16
    msr     sctlr_el1, x0
    isb

    // Enable FP/SIMD

    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0

    // Copy core 0's MMU config (MAIR, TCR, TTBR0, SCTLR are the same for all cores)

    mov     x0, #0xff
    msr     mair_el1, x0

    ldr     x0, =0x1B5183510
    msr     tcr_el1, x0
    isb

    ldr     x0, =boot_l0_table
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, xzr
    isb

    mrs     x0, sctlr_el1
    orr     x0, x0, #(1 << 0)
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    msr     sctlr_el1, x0
    isb

    // Install exception vectors

    ldr     x0, =exception_vectors
    msr     vbar_el1, x0
    isb

    // Pick per-core stack based on core ID (x19)

    cmp     x19, #1
    beq     .Lstack1
    cmp     x19, #2
    beq     .Lstack2

    // Core 3 (or any other)
    ldr     x0, =__core3_stack_top
    b       .Lstack_set

.Lstack1:
    ldr     x0, =__core1_stack_top
    b       .Lstack_set

.Lstack2:
    ldr     x0, =__core2_stack_top

.Lstack_set:

    mov     sp, x0

    // Pass core ID in x0, then jump to kmain_secondary

    mov     x0, x19
    b       kmain_secondary


// ---- Data ----

// Boot page tables - placed in BSS so the zero-loop clears them before use.
// Alignment requirements: 4KB for all levels (TTBR and descriptor pointers).
// Exported so page_table.zig can reference them to seed per-process tables.

.balign 4096

.global boot_l0_table
boot_l0_table:
    .space 4096

.global boot_l1_table
boot_l1_table:
    .space 4096

.global boot_l2_table
boot_l2_table:
    .space 4096      // 512 x 8-byte entries = 4096 bytes
