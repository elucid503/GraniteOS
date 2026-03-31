/* boot/linker.ld - GraniteOS kernel linker script (loads at 0x40000000, MMU off, physical == virtual) */

ENTRY(_start)

SECTIONS {

    . = 0x40000000; /* Load address of the kernel; physical == virtual with MMU off */

    /* .text.boot must come first so _start lands at the load address */

    .text : {

        KEEP(*(.text.boot))
        . = ALIGN(0x800);
        *(.text.vectors)
        *(.text .text.*)

    }

    .rodata : {

        *(.rodata .rodata.*)

    }

    .data : {

        *(.data .data.*)

    }

    /* .bss is not stored in the image; start.S zeroes it at boot */

    .bss (NOLOAD) : {

        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;

    }

    /* 64 KB kernel stack; ARM64 ABI requires 16-byte alignment */

    . = ALIGN(16);
    . += 64K;
    __stack_top = .;

    /* End of all kernel image data; physical allocator uses memory above this */

    __kernel_end = .;

    /DISCARD/ : {

        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.ARM.exidx*)

    }

}
