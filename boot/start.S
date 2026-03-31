// boot/start.S — ARM64 bootloader: halt non-zero cores, EL2 down to EL1 drop, BSS zero, stack, jump to kmain

.section ".text.boot"
.global _start

_start:

    // Halt all cores except core 0 (Aff0 field of MPIDR_EL1[7:0])

    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, .Lhalt

    // Drop from EL2 to EL1 if needed; skip if already at EL1

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    bne     .Lel1_already

    // HCR_EL2: RW bit (31) — EL1 runs AArch64, not AArch32

    mov     x0, #(1 << 31)
    msr     hcr_el2, x0

    // SCTLR_EL1: safe reset value — MMU off, caches off, little-endian

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

    // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11) — Zig may emit NEON instructions

    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0

    // Install exception vector table (VBAR_EL1)

    ldr     x0, =exception_vectors
    msr     vbar_el1, x0
    isb

    // Configure memory attributes:
    //   Attr0 = 0xFF = Normal memory (inner+outer write-back, read/write allocate)
    //   Attr1 = 0x00 = Device-nGnRnE (strongly ordered, no reordering or speculation)

    mov     x0, #0xff               // Attr0: normal WB cacheable; Attr1 stays 0 (device)
    msr     mair_el1, x0

    // Configure translation control for both address halves:
    //   T0SZ=16, T1SZ=16 — 48-bit VA space on each side
    //   4KB granule (TG0=0b00, TG1=0b10), inner-shareable WB caches
    //   IPS=0b001 (36-bit physical address — covers all QEMU virt RAM and devices)
    //   EPD1=1 — disable TTBR1 table walks; high-half accesses fault until kernel migrates there

    ldr     x0, =0x1B5183510
    msr     tcr_el1, x0
    isb

    // Build the two-level boot page table (L0 → L1) in pre-zeroed BSS.
    // Using 1GB block entries at L1 for simplicity — no L2/L3 needed at boot.

    // L0[0] → L1 table  (table descriptor: bits[1:0]=0b11, bits[47:12]=L1 PA)

    ldr     x0, =boot_l0_table
    ldr     x1, =boot_l1_table
    orr     x1, x1, #0x3            // table descriptor: valid=1, type=table=1
    str     x1, [x0]

    // L1[0] = 1GB device-memory block at PA 0x0
    //   Covers UART (0x09000000), GIC (0x08000000), and all other MMIO below 1GB
    //   Attrs: PXN=1, UXN=1, AF=1, SH=non-shareable, AttrIdx=1 (device), type=block

    ldr     x0, =boot_l1_table
    ldr     x1, =0x0060000000000405
    str     x1, [x0]

    // L1[1] = 1GB normal-memory block at PA 0x40000000
    //   Covers kernel image + entire 256MB RAM window
    //   Attrs: UXN=1, AF=1, SH=inner-shareable, AttrIdx=0 (normal WB), type=block

    ldr     x1, =0x0040000040000701
    str     x1, [x0, #8]

    // Ensure all page table stores reach memory before the table walker can see them

    dsb     sy

    // Point TTBR0 at the L0 table (low half = identity map).
    // Zero TTBR1 — EPD1 above means the hardware never walks it; high-half = fault.

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
    isb                             // pipeline flush — MMU is now active

    bl      kmain


.Lhalt:

    wfe
    b       .Lhalt


// Boot page tables — placed in BSS so the zero-loop in _start clears them before use.
// Both must be 4KB-aligned: TTBR0 requires L0 alignment; L0 descriptor requires L1 alignment.

.section .bss
.balign 4096 // 4KB alignment for page tables

boot_l0_table:
    .space 4096
boot_l1_table:
    .space 4096
