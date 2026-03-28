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

    bl      kmain


.Lhalt:

    wfe
    b       .Lhalt
