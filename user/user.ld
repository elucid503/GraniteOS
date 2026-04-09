/* user/user.ld - Linker script for GraniteOS user programs.
   Loads at 0x41000000, inside the identity-mapped normal-memory region. */

ENTRY(_start)

SECTIONS {

    . = 0x41000000;

    .text : { *(.text .text.*) }

    .rodata : { *(.rodata .rodata.*) }

    .data : { *(.data .data.*) }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.ARM.exidx*)
    }

}
