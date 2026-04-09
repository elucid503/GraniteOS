The problem:** User processes reach EL0 at VA `0x41000000` but immediately fault with "Undefined Instruction" (EC=0x00).

QEMU confirms: `Exception return from EL1 to EL0 PC 0x41000000` → immediately → `Taking exception 1 [Undefined Instruction]`. The page **is** mapped (no translation fault), but the CPU reads zeros/garbage instead of the actual ELF code bytes.

**Root cause candidates:**

1. **Wrong physical page being executed.** The ELF loader maps and writes code to PA1 under the per-process table. But when the scheduler later switches to the per-process table and the CPU fetches from `0x41000000`, the TLB walk might resolve to a different PA (e.g., the freshly-allocated L3 table page for `hello`'s load overwrote something, or the mapping in the page table was overwritten).

2. **D→I cache coherency** (less likely in QEMU since caches aren't simulated — writes are immediately visible). Added `DC CVAU` + `IC IVAU` maintenance in `load_segment` but it didn't help.

3. **The `switch_to(boot_root())` after loading flushes the non-global user TLB entries** (`vmalle1is`). When the scheduler later calls `switch_to(process_l0)`, it flushes again — but the CPU must re-walk the per-process page table. If those page table pages (L3 tables) were allocated from the same physical pool and then recycled or overwritten during `hello`'s load, the walk would get a corrupt L3 entry.

**Most likely:** The physical pages holding the L3 tables or the code pages are being allocated in the same range that the second ELF load (`hello`) also allocates from. Since both processes map `0x41000000`, they each get their own L3 table — but those L3 table pages are allocated sequentially. If the process.zig sequence (create table → switch → load → switch back → create table → switch → load → switch back) leaves any cross-contamination in the allocator or page table walk, the first process's L3 entries could be wrong.

**Next diagnostic step:** Print the L3 entry for VA `0x41000000` right before the `eret` (or print the first 4 bytes at the entry point VA while the per-process table is still active) to confirm whether the page table entry and physical page content are correct at execution time.
