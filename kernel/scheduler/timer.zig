// kernel/scheduler/timer.zig - ARM Generic Timer (EL1 physical timer, PPI INTID 30)

pub const INTERRUPT_ID: u32 = 30;

var ticks_per_quantum: u64 = 0;

pub fn init() void {

    const frequency = asm volatile ("mrs %[out], cntfrq_el0"

        : [out] "=r" (-> u64),

    );

    ticks_per_quantum = frequency / 10; // 100ms quantum

    asm volatile ("msr cntp_tval_el0, %[val]" : : [val] "r" (ticks_per_quantum));
    asm volatile ("msr cntp_ctl_el0, %[val]" : : [val] "r" (@as(u64, 1)));

}

pub fn reset() void {

    asm volatile ("msr cntp_tval_el0, %[val]" : : [val] "r" (ticks_per_quantum));

}
