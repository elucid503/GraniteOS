// kernel/sync/mutex.zig - ARM64 mutex using atomic compare-and-swap with WFE/SEV

pub const Mutex = struct {

    state: u32 = 0, // 0 = unlocked, 1 = locked

    /// Acquires the mutex. Spins with WFE until the CAS succeeds.
    pub fn lock(self: *Mutex) void {

        while (true) {

            if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;

            asm volatile ("wfe"); // low-power spin

        }

    }

    /// Releases the mutex. Store-release ensures all prior writes are visible; SEV wakes waiters.
    pub fn unlock(self: *Mutex) void {

        @atomicStore(u32, &self.state, 0, .release);

        asm volatile ("sev");

    }

};
