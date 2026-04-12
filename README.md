# GraniteOS

A proof-of-concept operating system targeting ARM64. The bootloader is written in ARM64 assembly; the kernel is written in Zig. All development and testing runs under QEMU on a Linux host.

---

## Design Goals

- Minimal, readable, well-structured code
- Sufficient to boot, run user processes, and demonstrate core OS concepts
- No unnecessary abstractions - complexity is added only when required

---

## Component Requirements

### 1. Bootloader (ARM64 Assembly)

**Responsibility:** Bring the hardware to a state where the Zig kernel can execute.

- Execute at EL1 (or drop from EL2 if QEMU starts there)
- Zero-initialize BSS segment
- Set up the initial stack pointer
- Configure UART for early debug output
- Enable the MMU with a minimal identity-mapped page table (so the kernel can set up its own)
- Jump to the Zig kernel entry point (`kmain`)

**Files:** `boot/start.S`, `boot/linker.ld`

---

### 2. Memory Management

**Virtual Memory (required)**

- Identity-map physical memory during boot so early kernel code can run before the full page tables are ready
- Set up a kernel page table using 4KB pages across a 48-bit virtual address space
- Separate kernel and user address spaces: kernel lives at the top of the address space (high addresses), user processes at the bottom (low addresses). ARM64 uses two page table registers - one for each half - so the split is hardware-enforced with no overlap
- Page fault handler to catch invalid memory accesses and panic cleanly rather than silently corrupting state

**Physical Allocator**

- Bitmap or free-list allocator over available RAM
- `alloc_page()` / `free_page()` primitives
- No dynamic allocator needed early on; add a slab/pool allocator once processes are running

**Kernel Heap**

- Simple bump allocator initially
- Upgrade to a free-list allocator (e.g. TLSF) once fragmentation becomes a problem

---

### 3. Interrupts and Exceptions

- Set up the ARM64 exception vector table (`VBAR_EL1`)
- Handle the four exception classes: synchronous, IRQ, FIQ, SError - for both EL0 and EL1
- Configure the GIC (Generic Interrupt Controller) for QEMU's `virt` machine
- Timer interrupt via ARM generic timer (`CNTP_CTL_EL0`) - drives the scheduler
- Syscall entry via `svc #0` (synchronous exception from EL0)

---

### 4. Scheduler

**Algorithm: Round Robin**

Round Robin is the right call for a PoC. It is simple, fair, and trivially correct. The only upgrade worth considering later is **Multi-Level Feedback Queue (MLFQ)**, which automatically handles the interactive vs. batch trade-off without requiring per-process priority tuning. Defer that until it is needed.

**Process Control Block (PCB)**

Each process has a PCB - a kernel-side record of everything needed to pause and resume it. It holds:

- **Process ID** - unique numeric identifier for this process
- **State** - one of: Ready (waiting for CPU), Running (currently executing), Blocked (waiting on I/O or a lock), or Zombie (exited but not yet cleaned up by parent)
- **General-purpose registers** - the 31 CPU registers (x0–x30) saved when the process is preempted
- **Stack pointer** - the user-space stack position at the time of preemption
- **Program counter** - where to resume execution
- **Processor state** - CPU flags and mode bits (condition codes, interrupt mask, etc.)
- **Page table pointer** - the process's own virtual memory map, swapped in on every context switch
- **Kernel stack pointer** - a separate stack used while handling syscalls and exceptions on behalf of this process
- **Parent PID** - which process spawned this one (needed for `wait`/`exit`)
- **Exit code** - the value passed to `exit()`, held until the parent reads it

**Context Switch**

- When the timer fires: save the current process's CPU registers into its PCB, select the next process from the queue, restore its registers, and return - from that process's perspective, it never stopped
- The user-space page table must be swapped on every context switch so each process sees only its own memory
- After swapping the page table, the CPU's translation cache (TLB) must be flushed, otherwise stale address mappings from the previous process will linger and cause incorrect memory accesses

**Scheduling Queue**

- Circular queue of ready PCBs
- Blocked processes removed from queue, re-added when unblocked

---

### 5. System Calls

The syscall calling convention mirrors Linux on AArch64 - this means standard toolchains and libc ports work without modification. When a process issues a syscall, it places the syscall number in register `x8`, up to six arguments in `x0` through `x5`, and reads the return value back from `x0` after the kernel returns.

**Required syscalls to support user binaries:**

| Number | Name       | Description                        |
|--------|------------|------------------------------------|
| 1      | `write`    | Write bytes to a file descriptor   |
| 3      | `close`    | Close a file descriptor            |
| 56     | `openat`   | Open a file                        |
| 57     | `close`    | (alias)                            |
| 63     | `read`     | Read bytes from a file descriptor  |
| 93     | `exit`     | Terminate current process          |
| 172    | `getpid`   | Return current PID                 |
| 214    | `brk`      | Grow/shrink the heap               |
| 220    | `clone`    | Create a new process (fork-like)   |
| 221    | `execve`   | Replace process image with ELF     |
| 260    | `wait4`    | Wait for a child process           |

Start with `write`, `exit`, `getpid`, and `brk`. Add the rest as needed.

---

### 6. Process Loading (ELF)

To support running custom binaries:

- Parse ELF64 headers (check magic, architecture, entry point)
- Load `PT_LOAD` segments into freshly-allocated user pages with correct permissions (R/W/X)
- Map a user stack (fixed address, e.g. `0x0000_7FFF_F000_0000`, growing down)
- Set `PC = e_entry`, `SP = top of user stack`
- Switch to EL0 and jump

**ELF Loader steps:**

1. Read and validate the ELF header - check the magic bytes, confirm it's a 64-bit ARM binary, and extract the entry point address
2. For each loadable segment: allocate fresh pages, copy the segment data in, and apply the correct permissions (read, write, or execute)
3. Allocate and map a user stack at a fixed high address, growing downward
4. Set up the initial stack frame with argc, argv, and envp - these can be empty or zeroed for a PoC
5. Return to user space at the entry point via `eret`

---

### 7. File System (Minimal)

A full VFS is a lot of work. For a PoC, a **ramfs** (in-memory filesystem) is sufficient:

- Fixed array or linked list of files, each with a name and a byte buffer
- `open`, `read`, `write`, `close` map to this structure
- No directories required initially (flat namespace)
- Binaries are embedded in the kernel image (via `@embedFile` in Zig) or loaded from a simple initrd

Later, add a real disk-backed filesystem (e.g. FAT32 or a custom format) once VirtIO block support is added.

---

### 8. User/Kernel Mode Switching

- User processes run at privilege level EL0 (unprivileged); the kernel runs at EL1
- Entering the kernel happens via `svc #0` for syscalls, or automatically on any exception or interrupt
- Returning to user space uses the `eret` instruction, which atomically restores the saved program counter and processor state - there is no way for user code to fake this
- Each process has its own dedicated kernel stack, used only while the kernel is handling an exception or syscall on that process's behalf
- The hardware maintains two separate stack pointers: one for user space (EL0) and one for the kernel (EL1), so they never interfere

---

### 9. IPC (Inter-Process Communication)

Start simple. The minimum viable set:

**Pipes (first)**
- Kernel-managed ring buffer
- Two file descriptors (read end, write end)
- Blocked read if buffer empty; blocked write if buffer full
- Fits naturally into the fd/syscall model already needed

**Shared Memory (later)**
- `mmap`-style syscall to map a named region into two processes' address spaces
- Requires careful TLB and cache management on ARM64
- Add only after pipes are working

**Signals (later)**
- Async notification mechanism
- Required to make `wait`/`exit` work cleanly across processes
- Minimum: `SIGCHLD`, `SIGKILL`, `SIGTERM`

---

### 10. Multicore Support

For a PoC, start single-core. Multicore adds significant complexity:

- Each core needs its own exception vectors, stack, and GIC CPU interface
- The scheduler needs a run queue per core plus work-stealing or migration
- All shared kernel data structures need spinlocks (`ldaxr`/`stlxr` on ARM64)
- Memory ordering: ARM64 is weakly ordered - `dmb`, `dsb`, `isb` barriers required at correct points

**Recommended approach:** bring up a second core only after the single-core kernel is stable. Use `PSCI` (via QEMU) to bring secondary cores online.

---

### 11. CLI / Shell

A minimal shell is sufficient for a PoC:

- UART-backed terminal (reads chars, echoes them)
- Line buffering with backspace support
- `fork` + `exec` on Enter: look up binary in ramfs, load and run it
- Built-ins: `help`, `ls`, `clear`, `exit`

No job control, no pipes in the shell (even if kernel supports them) - keep it minimal.

---

### 12. Drivers (Minimal Set)

| Driver            | Purpose                          | QEMU device         |
|-------------------|----------------------------------|---------------------|
| PL011 UART        | Serial console I/O               | `virt` default UART |
| ARM Generic Timer | Scheduling timer interrupt       | Built into CPU      |
| GICv2/v3          | Interrupt controller             | `virt` GIC          |
| VirtIO Block      | Disk access (later)              | `-drive` + VirtIO   |

---

## End-to-End: Supporting Custom Binaries

This is the full chain required before a user-compiled binary can run on GraniteOS:

```
1. User compiles a C or Zig program targeting aarch64-freestanding
   -> produces an ELF64 binary

2. Binary is placed into the ramfs image
   (embedded in kernel at build time, or loaded from initrd)

3. Shell calls fork() -> child calls execve("/programs/hello", ...)

4. Kernel execve handler:
   a. Loads ELF: allocates user pages, copies segments
   b. Sets up user stack with argc/argv
   c. Creates/updates PCB with new PC, SP, page table
   d. Returns to EL0 at ELF entry point

5. Process runs in user space, making syscalls via svc #0

6. Process calls exit(0) -> kernel marks PCB as Zombie
   -> parent's wait4() is unblocked -> PCB freed

7. Shell prints prompt again
```

**Minimum kernel features required before step 3 works:**
- Virtual memory (user address space)
- ELF loader
- Syscalls: `exit`, `write`, `brk` (for malloc in libc)
- UART driver (so `write(1, ...)` produces output)
- Scheduler (so the process actually gets CPU time)

---

## Development Milestones

| Milestone | Goal                                                    |
|-----------|---------------------------------------------------------|
| M1        | Boot in QEMU, print "Hello" over UART                   |
| M2        | Exception vectors, timer IRQ, basic scheduler (no user) |
| M3        | Virtual memory, kernel heap                             |
| M4        | EL0 switch, run a hardcoded user function               |
| M5        | ELF loader, run a compiled binary                       |
| M6        | Syscalls: write, exit, brk                              |
| M7        | Ramfs, shell, fork/exec                                 |
| M8        | Pipes, signals, wait/exit                               |
| M9        | VirtIO block, FAT32 (optional)                          |
| M10       | Second core (optional)                                  |

---

## Toolchain Setup

### Install Zig

```bash
# Download latest stable Zig (0.13.x or later)
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /opt/zig
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc
source ~/.bashrc
zig version
```

### Cross-Compile Target

Zig has built-in cross-compilation. For the kernel:

```bash
zig build-exe kernel.zig \
  -target aarch64-freestanding-none \
  -O ReleaseSafe \
  -T linker.ld
```

### QEMU Run Command

```bash
qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a57 \
  -m 256M \
  -nographic \
  -kernel kernel.elf \
  -serial mon:stdio
```

### Cross-Assembler (for bootloader)

```bash
sudo apt install binutils-aarch64-linux-gnu
aarch64-linux-gnu-as boot/start.S -o boot/start.o
aarch64-linux-gnu-ld -T boot/linker.ld boot/start.o -o kernel.elf
```

Or let Zig drive the whole build (including the `.S` file) via `build.zig`.

---

## Areas Not Covered Above (Worth Considering)

- **Kernel debugging:** QEMU's `-s -S` flags expose a GDB stub. Use `gdb-multiarch` with an AArch64 target. Set this up before writing any real code.
- **UART early panic:** A `panic()` function that prints to UART and halts is the single most useful debugging tool in early kernel development.
- **Stack overflow detection:** Place a guard page (unmapped) below each kernel stack. A stack overflow becomes a clean page fault rather than silent corruption.
- **KASLR / security:** Not relevant for a PoC - skip entirely.
- **SMP-safe allocators:** Not needed until M10.
