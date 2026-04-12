// boot/vectors.S - ARM64 exception vector table

// 16 entries (4 exception types × 4 source contexts), each 128 bytes.
// Table is 2KB aligned.

// Frame layout (272 bytes):
//   [sp, #0]...[sp, #240]  x0–x30
//   [sp, #248]             ELR_EL1 (return address)
//   [sp, #256]             SPSR_EL1 (saved processor state)
//   [sp, #264]             SP_EL0 (user stack pointer; 0 for EL1 tasks)

.section .text.vectors, "ax"
.balign 0x800 // alignment

.global exception_vectors

exception_vectors:

// Current EL, SP_EL0 (unused - we always use SP_ELx)

.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled

// Current EL, SP_ELx (kernel takes interrupts here)

.balign 0x80
    b       _unhandled              // Synchronous
.balign 0x80
    b       _irq                    // IRQ - timer fires here
.balign 0x80
    b       _unhandled              // FIQ
.balign 0x80
    b       _unhandled              // SError

// Lower EL, AArch64 (user-space EL0)

.balign 0x80
    b       _el0_sync               // Synchronous - SVC syscall entry
.balign 0x80
    b       _el0_irq                // IRQ - timer preempts user task
.balign 0x80
    b       _unhandled              // FIQ
.balign 0x80
    b       _unhandled              // SError

// Lower EL, AArch32 (unsupported)

.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled
.balign 0x80
    b       _unhandled

// save_regs: allocate a 272-byte frame and save all caller/callee registers,
// ELR_EL1, SPSR_EL1, and SP_EL0 (user stack; 0 for EL1 tasks).

.macro save_regs
    sub     sp, sp, #272
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30,       [sp, #240]
    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    mrs     x2, sp_el0
    stp     x0,  x1,  [sp, #248]
    str     x2,        [sp, #264]
.endm

// restore_regs: restore SP_EL0 first, then all registers, then pop the frame.
// SP_EL0 must be restored before eret so the CPU has the right user stack.

.macro restore_regs
    ldr     x2,        [sp, #264]
    msr     sp_el0, x2
    ldp     x0,  x1,  [sp, #248]
    msr     elr_el1, x0
    msr     spsr_el1, x1
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30,       [sp, #240]
    add     sp, sp, #272
.endm

// EL1 IRQ: timer or device interrupt while kernel is running.

_irq:

    save_regs

    mov     x0, sp
    bl      handle_irq              // Zig handler; returns new SP in x0

    mov     sp, x0
    restore_regs

    eret

// EL0 IRQ: timer interrupt preempts a user-space task.
// Identical body to _irq - hardware routes here from a different vector entry.

_el0_irq:

    save_regs

    mov     x0, sp
    bl      handle_irq

    mov     sp, x0
    restore_regs

    eret

// EL0 synchronous: svc #0 syscall from user space, or fault (abort, alignment, etc.)
// Read ESR_EL1.EC to distinguish SVC (0x15) from aborts before dispatching.

_el0_sync:

    save_regs

    mrs     x9,  esr_el1
    lsr     x9,  x9,  #26          // EC = ESR[31:26]
    and     x9,  x9,  #0x3F
    cmp     x9,  #0x15             // SVC instruction executed in AArch64 state
    bne     .Lel0_fault            // anything else -> fault handler

    mov     x0, sp
    bl      handle_syscall          // Zig handler; returns new (or same) SP in x0

    mov     sp, x0
    restore_regs
    eret

.Lel0_fault:

    // Non-SVC EL0 sync exception (data abort, instruction abort, etc.)
    mrs     x0, esr_el1
    mrs     x1, elr_el1
    bl      handle_unhandled        // noreturn
    b       .

_unhandled:

    save_regs

    mrs     x0, esr_el1             // arg 0: exception syndrome
    mrs     x1, elr_el1             // arg 1: faulting address

    bl      handle_unhandled        // noreturn
    b       .
