// kernel/sync/mutex.zig - ARM64 mutex using atomic operations + WFE/SEV

pub const Mutex = struct {

    state: u32 = 0, // 0 = unlocked, 1 = locked

    /// Acquire the mutex. Spins with WFE until successful.
    pub fn lock(self: *Mutex) void {

        while (true) {

            // Atomic compare-and-swap: if state==0, set to 1
            if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;

            // Failed - wait for event (low-power spin)
            asm volatile ("wfe");

        }

    }

    /// Release the mutex. Store-release ensures all prior writes are visible
    /// before the lock appears free. SEV wakes any core spinning in WFE.
    pub fn unlock(self: *Mutex) void {

        @atomicStore(u32, &self.state, 0, .release);

        asm volatile ("sev");

    }

};
