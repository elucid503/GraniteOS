# GraniteOS

An ARM64 operating system ran on top of QEMU, written in Zig (kernel) and ARM64 assembly (bootloader), with an implementation of virtual memory, process scheduling, exception handling, syscalls, ELF loading, and interprocess communication.

## Overview

GraniteOS boots on QEMU's `virt` machine, runs a full shell environment with user programs, and supports multiprocess execution with pipes and signals. The kernel is minimal but complete with no unnecessary abstractions. Every component serves a concrete purpose.

**Target Platform:** ARM64 (AArch64) on QEMU  
**Kernel:** ~5,000 lines of Zig  
**Bootloader:** ~300 lines of ARM64 assembly  
**User Space:** ~1,500 lines of Zig (shell, utilities, testers)

## Quick Start

### Build

```bash
zig build
```

Builds the kernel with all embedded user programs. The build system automatically discovers and compiles all programs in `user/programs/*`.

### Run

```bash
zig build qemu
```

Boots GraniteOS in QEMU. You'll see the SLATE launcher, which immediately spawns the BASALT shell.

## Important User Binaries

1. SLATE - System Launch And Task Executor
2. BASALT - Basic Adaptive Shell And Lightweight Terminal

## Architecture

### Boot Sequence

1. **ARM64 Bootloader** (`boot/start.S`)
   - Halts all cores except core 0
   - Drops from EL2 to EL1 if needed
   - Zero-es out BSS segment
   - Builds two-level page tables:
     - L0 table (single entry)
     - L1 table (device memory block + L2 table pointer)
     - L2 table (512 × 2MB blocks for kernel and user space)
   - Enables MMU with identity mapping
   - Jumps to kernel entry point (`kmain`)

2. **Kernel Initialization** (`kernel/kmain.zig`)
   - Initializes UART (console I/O)
   - Initializes physical memory allocator
   - Initializes kernel heap
   - Initializes file system
   - Initializes GIC (interrupt controller)
   - Starts timer (100ms ticks)
   - Spawns first user process (SLATE)
   - Enables interrupts

### Memory Management

**Virtual Address Space**
- Kernel (high half): 0x4000_0000 – 0x7FFF_FFFF (identity-mapped, is read-only for EL0, as it should be)
- User (low half): 0x0000_0000 – 0x3FFF_FFFF (per-process, has no kernel visibility)
- Hardware logically enforces split via separate user and kernel registers

**Physical Allocator**
- Bitmap-based allocator over available RAM
- 4KB pages, with up to 256MB of RAM (this is configurable)
- Efficient alloc/free with fragmentation tracking

**Page Tables**
- 4-level hierarchical translation (L0, L1, L2, L3)
- Per-process L0 table is created on fork
- Kernel regions are shared and marked non-global so TLB flushes don't affect them
- User regions deliberately marked non-global for ensuring TLB invalidation on context switch

### Processes and Scheduling

**Process Control Block (PCB)**

Each process contains:
- PID, parent PID, exit code
- State: ready, running, blocked, or zombie
- 31 general-purpose registers (x0–x30)
- Program counter and stack pointer (saved on preemption)
- Processor state register (ELR_EL1, SPSR_EL1)
- User page table pointer
- Kernel stack (8KB per process)
- File descriptor table
- Signal handler table

**Scheduler**
- Round-robin algorithm with a 100ms time quantum
- Circular ready process queue
- Processes enter queue when ready, leave when blocked or exit
- Context switch: saves current registers into PCB, restores next process, swaps page table, flushes TLB

**System Calls**

26 (non-POSIX) syscalls implement the core OS interface:

| Num | Name | Purpose |
|-----|------|---------|
| 1 | write | Write to file descriptor |
| 2 | read | Read from file descriptor |
| 3 | exit | Terminate process |
| 4 | getpid | Get process ID |
| 5 | fork | Clone current process |
| 6 | execve | Load and run new binary |
| 7 | brk | Grow/shrink heap |
| 8 | wait4 | Wait for child process |
| 9 | open | Open file |
| 10 | close | Close file descriptor |
| 11 | pipe | Create pipe |
| 12 | create | Create file |
| 13 | kill | Send signal to process |
| 14 | sigaction | Install signal handler |
| 15 | sigreturn | Return from signal handler |
| 16 | dup2 | Duplicate file descriptor |
| 17 | listprogs | List available programs |
| 18 | delete | Delete file |
| 19 | rename | Rename file |
| 20 | listfiles | List files in directory |
| 21 | sysinfo | Get system info |
| 22 | chmod | Change file permissions |
| 23 | chdir | Change directory |
| 24 | mkdir | Create directory |
| 25 | rmdir | Remove directory |
| 26 | getcwd | Get current working directory |

Syscalls enter via `svc #0` exception from EL0, dispatched in `kernel/syscall/syscall.zig`.

### Exception Handling

**Vector Table** (`boot/vectors.S`)
- 16 exception entry points (4 types × 4 contexts)
- Each handler has 128 bytes (common practice on ARM64)
- Saves full CPU state (31 registers + ELR + SPSR + SP_EL0) into 272-byte frame

**Exception Types**
- Synchronous: syscalls, page faults, instruction errors
- IRQ: timer, GIC-routed interrupts
- FIQ: fast interrupts (unused here)
- SError: system errors (unused here)

**Key Handlers**
- `_el0_sync`: Syscall dispatch; page fault panic
- `_el0_irq`: Timer preempts user process, triggers context switch
- `_el1_irq`: Kernel running; typically a bug (would indicate nested interrupt)

### File System

**In-Memory Hierarchical FS** (`kernel/fs/fs.zig`)
- Up to 64 files/directories supported (is configurable, but depends on RAM size)
- Flat namespace with directory support (parent pointers)
- File kinds: empty, file, directory, program (embedded binary)
- Permissions: owner read/write, anyone read/write
- Max file size: 4KB (also configurable)

**Embedded Programs**
- User programs are compiled to ELF and embedded into the kernel via `@embedFile` at build time
- File system exposes them as entries under `/programs/`
- Accessible via the `listprogs` syscall
- Registry in kernel tracks program metadata (name, size, permissions)

**Pipes**
- Buffer-driven (4KB capacity)
- Reader/writer reference counts
- Blocks reader if empty, blocks writer if full
- Created via `pipe` syscall, used with `fork` and `exec` for shell pipelines

### Signals

**Minimal Signal Support** (`kernel/signal/signal.zig`)
- 4 signals max per process: SIGCHLD, SIGTERM, SIGKILL, custom
- Handler: kernel-space or user-space with signal frame injection
- Restores user state via `sigreturn` syscall after handler runs

### Drivers

**UART** (`kernel/drivers/uart.zig`)
- PL011 UART at address 0x09000000
- Prints kernel messages and handles console I/O
- `write(1, ...)` syscalls route here

**GIC** (`kernel/drivers/gic.zig`)
- ARM Generic Interrupt Controller (v2/v3 compatible)
- Configures timer interrupt line
- Routes interrupts to CPU

**Timer** (`kernel/scheduler/timer.zig`)
- ARM generic timer (CNTP_TVAL_EL0)
- 100ms period, triggers scheduler context switch
- Interrupt-driven, no polling

## Building User Programs

User programs live in `user/programs/` under category directories. Each `.zig` file becomes an executable.

**Available Programs**

**Global:**
- `slate`: System launcher (spawns shell, restarts if it exits)
- `basalt`: Interactive shell with pipe support

**Common:**
- `echo`: Print arguments
- `hello`: Print "Hello, World!"
- `help`: List available commands
- `about`: OS information
- `status`: Show system status
- `clear`: Clear screen
- `cat`: Display file contents
- `wc`: Word/line count

**File System:**
- `ls`: List directory
- `mkdir`: Create directory
- `create`: Create file
- `edit`: Edit file contents
- `view`: View file
- `delete`: Remove file
- `rename`: Rename file
- `own`: Change file owner
- `chmod`: Change permissions

**Location:**
- `path`: Show current directory

**Testers:**
- `fork_test`: Stress test forking
- `sched_test`: Test scheduler (round-robin verification)
- `pipe_test`: Test pipes and I/O
- `signal_test`: Test signals

All programs link against the user library (`user/lib/`):
- `syscall.zig`: Raw syscall wrappers
- `io.zig`: Print, read line, formatting
- `mem.zig`: Simple allocator for user space

## Shell (BASALT)

Basic Adaptive Shell And Lightweight Terminal (BASALT) is a lightweight shell supporting:

- **Command execution:** Type a program name and press Enter
- **Pipes:** `cmd1 | cmd2 | cmd3` (fully functional)
- **Builtins:**
  - `help` – show available programs
  - `path` – show current directory
  - `cd DIR` – change directory
  - `exit` – quit shell
- **Output redirection:** Not yet supported

Commands fork, exec the binary from the file system, and wait for completion.

## Other Commentary

### Bootloader Design

The two-level page table in assembly (`boot/start.S`) is built once and reused:
- L0 (4KB): single entry pointing to L1
- L1 (4KB): first entry is 1GB device block; second entry points to L2
- L2 (4KB): 512 x 2MB blocks for kernel (UXN, no EL0 execution) and user (PXN, no EL1 execution)

This gives fine-grained control: kernel code is executable by EL1 only, user code is executable by EL0 only.

### Per-Process Page Tables

When a process is created (fork or execve), the kernel:
1. Clones the boot L2 table
2. Creates a new L0 that points to the cloned L2
3. Swaps in its own L0 on context switch
4. Ensures shared kernel regions (marked non-global) are TLB-flushed efficiently

### Exception Frame Design

A single 272-byte frame layout for all exceptions (defined in `boot/vectors.S`, mirrored in Zig structs):
- Saves all 31 registers + 3 control registers
- Is aligned for efficient loading/storing
- Syscall handlers read frame pointer from SP_EL1, extract arguments from x0–x5

### Syscall Dispatch

Custom syscall numbers (1–26) defined in `user/lib/syscall.zig` and `kernel/syscall/syscall.zig` for clarity. While syscall numbers aren't POSIX compliant, the register calling convention matches ARM64 ABI: syscall number in x8, up to 6 args in x0–x5, return value in x0.

### ELF Loading

Fully compliant ELF64 AArch64 loader (`kernel/process/elf_loader.zig`):
- Validates magic bytes, architecture of binary, the executable flag
- Loads `PT_LOAD` segments into user pages with correct permissions
- Allocates and maps user stack (8KB, grows downward)
- Sets up stack frame with argument count and vector
- Returns to user space at entry point
- Entry point is _start(), not main()

## Development Notes

### Adding a New Program

1. Create `user/programs/CATEGORY/myprogram.zig`
2. Implement `export fn _start() noreturn { ... }` or `export fn _start(argc, argv) noreturn { ... }`
3. Run `zig build` – it will auto-discover and put it into the file system
4. Test via shell: `myprogram`

### Testing

Can run test programs to verify core functionality:
```bash
# In shell, after startup:
sched_test # Verify round-robin scheduling
fork_test # Verify fork and process isolation
pipe_test # Verify pipes and redirection
signal_test # Verify signal delivery
```

### Performance

- Timer-driven scheduling (100ms quantum)
- Efficient TLB invalidation via non-global page bit
- No dynamic allocation in hot paths (allocator only used at boot)
- Bitmap-based physical allocator (O(1) fragmentation check)

### Known Limitations

- Fixed file size limit (4KB) and max file count (64)
- Limited memory protection beyond page-level
- There is no preemption of kernel mode (kernel is not preemptible)
- Per-process signals are a basic implementation (with only essential ones)

## License

GraniteOS is a learning project for an Operating Systems course. Not intended for actual use. No license provided.
