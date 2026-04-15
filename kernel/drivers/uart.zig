// kernel/drivers/uart.zig - PL011 UART driver (polling) at 0x09000000 (QEMU virt)

const UART_BASE: usize = 0x09000000;

const data_register = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x000));
const flag_register = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x018));
const baud_int_divisor = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x024));
const baud_frac_divisor = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x028));
const line_control = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x02C));
const control = @as(*volatile u32, @ptrFromInt(UART_BASE + 0x030));

const tx_fifo_full: u32 = 1 << 5; // Flag register bit 5

// Configures for 38400 8N1: 24MHz clock, IBRD=39, FBRD=4 (24M / (16 * 38400))

pub fn init() void {

    control.* = 0; // Disable UART before reconfiguring
    baud_int_divisor.* = 39;
    baud_frac_divisor.* = 4;
    line_control.* = (1 << 4) | (0b11 << 5); // WLEN=0b11 -> 8-bit words, FIFO enabled
    control.* = (1 << 0) | (1 << 8) | (1 << 9); // Enable UART, TX, RX

}

pub fn putchar(c: u8) void {

    while (flag_register.* & tx_fifo_full != 0) {} // Spin until TX FIFO has space
    data_register.* = c;

}

pub fn print(s: []const u8) void {

    for (s) |c| {

        putchar(c);

    }

}

/// Return one character from the RX FIFO, or null if none is waiting.
pub fn getchar() ?u8 {

    const rx_fifo_empty: u32 = 1 << 4; // Flag register RXFE bit

    if (flag_register.* & rx_fifo_empty != 0) return null;

    return @truncate(data_register.*);

}

pub fn print_hex(value: u64) void {

    const digits = "0123456789abcdef";

    putchar('0');
    putchar('x');

    var shift: u7 = 60;

    while (true) {

        const nibble: u4 = @truncate(value >> @as(u6, @intCast(shift)));

        putchar(digits[nibble]);

        if (shift == 0) break;
        shift -= 4;

    }

}
