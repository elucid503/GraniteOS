// kernel/signal/signal.zig - GraniteOS process signals

const scheduler = @import("../scheduler/scheduler.zig");
const fs = @import("../fs/fs.zig");

pub const SIGNAL_COUNT: usize = 4;

pub const Signal = enum(u3) {

    terminate = 0,
    interrupt = 1,
    stop = 2,
    cont = 3,

};

// Exception frame offsets (must match boot/vectors.S 272-byte layout)

const X0_OFFSET: usize = 0;
const X30_OFFSET: usize = 240;
const ELR_OFFSET: usize = 248;
const SP_EL0_OFFSET: usize = 264;

/// Sends a signal to the target process. Returns true on success.
pub fn send(target_pid: u32, sig: u3) bool {

    if (target_pid >= scheduler.process_count) return false;
    if (sig >= SIGNAL_COUNT) return false;

    const pcb = scheduler.get_process(target_pid) orelse return false;

    if (pcb.state == .empty or pcb.state == .zombie) return false;

    // SIGCONT unblocks a stopped process rather than pending
    if (sig == @intFromEnum(Signal.cont)) {

        if (pcb.stopped_by_signal) {

            pcb.stopped_by_signal = false;
            pcb.state = .ready;

        }

        return true;

    }

    pcb.pending_signals |= @as(u8, 1) << sig;
    return true;

}

/// Registers a signal handler. handler = 0 restores default behavior.
pub fn set_handler(sig: u3, handler: usize) bool {

    if (sig >= SIGNAL_COUNT) return false;

    const pcb = scheduler.current_process();
    pcb.signal_handlers[sig] = handler;

    return true;

}

/// Checks pending signals for the current process and delivers the first one. Called before eret to user space.
pub fn check_and_deliver(saved_sp: usize) usize {

    const pcb = scheduler.current_process();

    if (pcb.pending_signals == 0 or pcb.signal_delivering) return saved_sp;

    var sig: u3 = 0;

    while (sig < SIGNAL_COUNT) : (sig += 1) {

        if (pcb.pending_signals & (@as(u8, 1) << sig) == 0) continue;

        pcb.pending_signals &= ~(@as(u8, 1) << sig);

        const handler = pcb.signal_handlers[sig];

        if (handler != 0) {

            // Save context and rewrite exception frame to redirect to the user handler
            const frame: [*]u8 = @ptrFromInt(saved_sp);

            pcb.saved_signal_elr = read_u64(frame, ELR_OFFSET);
            pcb.saved_signal_sp = read_u64(frame, SP_EL0_OFFSET);
            pcb.saved_signal_x0 = read_u64(frame, X0_OFFSET);
            pcb.saved_signal_x30 = read_u64(frame, X30_OFFSET);
            pcb.signal_delivering = true;

            write_u64(frame, ELR_OFFSET, @intCast(handler));
            write_u64(frame, X0_OFFSET, sig);
            write_u64(frame, X30_OFFSET, 0); // fault cleanly if handler forgets sigreturn

            return saved_sp;

        }

        // Default actions

        switch (@as(Signal, @enumFromInt(sig))) {

            .terminate, .interrupt => {

                fs.close_all(pcb);
                return scheduler.exit_current(saved_sp);

            },

            .stop => {

                pcb.stopped_by_signal = true;
                return scheduler.block_current(saved_sp);

            },

            .cont => {},

        }

    }

    return saved_sp;

}

/// Restores context saved before signal delivery. Called by SYS_SIGRETURN.
pub fn sigreturn(saved_sp: usize) usize {

    const pcb = scheduler.current_process();

    if (!pcb.signal_delivering) return saved_sp;

    const frame: [*]u8 = @ptrFromInt(saved_sp);

    write_u64(frame, ELR_OFFSET, pcb.saved_signal_elr);
    write_u64(frame, SP_EL0_OFFSET, pcb.saved_signal_sp);
    write_u64(frame, X0_OFFSET, pcb.saved_signal_x0);
    write_u64(frame, X30_OFFSET, pcb.saved_signal_x30);

    pcb.signal_delivering = false;

    return saved_sp;

}

fn read_u64(base: [*]u8, offset: usize) u64 {

    return @as(*const u64, @alignCast(@ptrCast(base + offset))).*;

}

fn write_u64(base: [*]u8, offset: usize, value: u64) void {

    @as(*u64, @alignCast(@ptrCast(base + offset))).* = value;

}
