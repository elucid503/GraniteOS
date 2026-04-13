// kernel/drivers/extio.zig - Minimal virtio-mmio block device driver (polling)
//
// Scans QEMU virt's virtio-mmio transports at 0x0a000000 for a block device.
// Uses a single virtqueue with polling (no interrupts) for simple read/write.
// Supports both legacy (v1) and modern (v2) transports.

const sync = @import("../sync/mutex.zig");

const SECTOR_SIZE: usize = 512;

// QEMU virt machine: 32 virtio-mmio transports at 0x0a000000, stride 0x200
const VIRTIO_MMIO_BASE: usize = 0x0a000000;
const VIRTIO_MMIO_STRIDE: usize = 0x200;
const VIRTIO_MMIO_COUNT: usize = 32;

// virtio-mmio register offsets
const REG_MAGIC: usize = 0x000;
const REG_VERSION: usize = 0x004;
const REG_DEVICE_ID: usize = 0x008;
const REG_VENDOR_ID: usize = 0x00c;
const REG_HOST_FEATURES: usize = 0x010;
const REG_GUEST_FEATURES: usize = 0x020;
const REG_GUEST_PAGE_SIZE: usize = 0x028;
const REG_QUEUE_SEL: usize = 0x030;
const REG_QUEUE_NUM_MAX: usize = 0x034;
const REG_QUEUE_NUM: usize = 0x038;
const REG_QUEUE_ALIGN: usize = 0x03c;
const REG_QUEUE_PFN: usize = 0x040;
const REG_QUEUE_NOTIFY: usize = 0x050;
const REG_INTERRUPT_STATUS: usize = 0x060;
const REG_INTERRUPT_ACK: usize = 0x064;
const REG_STATUS: usize = 0x070;

// virtio status bits
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_DRIVER_OK: u32 = 4;

// virtio magic
const VIRTIO_MAGIC: u32 = 0x74726976; // "virt"

// Device ID for block device
const DEVICE_BLOCK: u32 = 2;

// Queue descriptor flags
const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2; // device writes to this buffer

// Block request types
const VIRTIO_BLK_T_IN: u32 = 0; // read from device
const VIRTIO_BLK_T_OUT: u32 = 1; // write to device

const QUEUE_SIZE: usize = 16;

// Virtqueue descriptor
const VirtqDesc = extern struct {

    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

};

// Virtqueue available ring
const VirtqAvail = extern struct {

    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]u16,

};

// Virtqueue used ring element
const VirtqUsedElem = extern struct {

    id: u32,
    len: u32,

};

// Virtqueue used ring
const VirtqUsed = extern struct {

    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]VirtqUsedElem,

};

// Block request header (16 bytes)
const VirtioBlkReq = extern struct {

    req_type: u32,
    reserved: u32,
    sector: u64,

};

// Contiguous vring memory required by the legacy (v1) PFN-based layout.
// The device computes avail/used offsets from a single base address, so all
// three rings must live at the correct fixed offsets within one allocation.
const VRING_DESC_AREA = QUEUE_SIZE * @sizeOf(VirtqDesc);
const VRING_AVAIL_AREA = @sizeOf(VirtqAvail);
const VRING_USED_ALIGN = 4096;

const VringLayout = extern struct {

    desc: [QUEUE_SIZE]VirtqDesc,
    avail: VirtqAvail,
    _pad: [VRING_USED_ALIGN - VRING_DESC_AREA - VRING_AVAIL_AREA]u8,
    used: VirtqUsed,

};

var vring: VringLayout align(4096) = undefined;

// Request header and status byte
var req_header: VirtioBlkReq align(16) = undefined;
var req_status: u8 align(4) = 0;

var base_addr: usize = 0;
var device_version: u32 = 0;
var last_used_idx: u16 = 0;
var initialized: bool = false;

var io_lock: sync.Mutex = .{};

fn mmio_read(offset: usize) u32 {

    return @as(*volatile u32, @ptrFromInt(base_addr + offset)).*;

}

fn mmio_write(offset: usize, value: u32) void {

    @as(*volatile u32, @ptrFromInt(base_addr + offset)).* = value;

}

/// Scan for a virtio block device and initialize it. Returns true on success.
pub fn init() bool {

    // Scan all 32 virtio-mmio slots for a block device

    for (0..VIRTIO_MMIO_COUNT) |i| {

        const addr = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
        const magic = @as(*volatile u32, @ptrFromInt(addr + REG_MAGIC)).*;

        if (magic != VIRTIO_MAGIC) continue;

        const dev_id = @as(*volatile u32, @ptrFromInt(addr + REG_DEVICE_ID)).*;

        if (dev_id != DEVICE_BLOCK) continue;

        base_addr = addr;
        device_version = @as(*volatile u32, @ptrFromInt(addr + REG_VERSION)).*;

        if (init_device()) {

            initialized = true;
            return true;

        }

    }

    return false;

}

fn init_device() bool {

    // Reset device
    mmio_write(REG_STATUS, 0);

    // Acknowledge + driver
    mmio_write(REG_STATUS, STATUS_ACKNOWLEDGE);
    mmio_write(REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Read features, accept none (minimal driver)
    _ = mmio_read(REG_HOST_FEATURES);
    mmio_write(REG_GUEST_FEATURES, 0);

    if (device_version >= 2) {

        mmio_write(REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

        if (mmio_read(REG_STATUS) & STATUS_FEATURES_OK == 0) return false;

    }

    // Set up queue 0
    mmio_write(REG_QUEUE_SEL, 0);

    const max_size = mmio_read(REG_QUEUE_NUM_MAX);
    if (max_size == 0) return false;

    const num: u32 = if (max_size < QUEUE_SIZE) max_size else QUEUE_SIZE;
    mmio_write(REG_QUEUE_NUM, num);

    // Initialize queue memory
    @memset(@as([*]u8, @ptrCast(&vring))[0..@sizeOf(VringLayout)], 0);
    vring.avail.flags = 1; // VIRTQ_AVAIL_F_NO_INTERRUPT — we poll, so suppress device interrupts
    last_used_idx = 0;

    if (device_version == 1) {

        // Legacy: set page size and queue PFN
        mmio_write(REG_GUEST_PAGE_SIZE, 4096);
        mmio_write(REG_QUEUE_ALIGN, 4096);
        mmio_write(REG_QUEUE_PFN, @intCast(@intFromPtr(&vring) >> 12));

    } else {

        // Modern: set individual queue addresses
        const desc_addr = @intFromPtr(&vring.desc);
        const avail_addr = @intFromPtr(&vring.avail);
        const used_addr = @intFromPtr(&vring.used);

        mmio_write(0x080, @intCast(desc_addr & 0xFFFFFFFF)); // QueueDescLow
        mmio_write(0x084, @intCast(desc_addr >> 32)); // QueueDescHigh
        mmio_write(0x090, @intCast(avail_addr & 0xFFFFFFFF)); // QueueDriverLow
        mmio_write(0x094, @intCast(avail_addr >> 32)); // QueueDriverHigh
        mmio_write(0x0a0, @intCast(used_addr & 0xFFFFFFFF)); // QueueDeviceLow
        mmio_write(0x0a4, @intCast(used_addr >> 32)); // QueueDeviceHigh
        mmio_write(0x044, 1); // QueueReady

    }

    // Driver OK -- must preserve FEATURES_OK for v2+ or the device rejects requests
    const ok_status = STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK |
        if (device_version >= 2) STATUS_FEATURES_OK else 0;
    mmio_write(REG_STATUS, ok_status);

    return true;

}

/// Read one 512-byte sector from the block device. Returns true on success.
pub fn read_sector(sector: u64, buf: [*]u8) bool {

    if (!initialized) return false;

    io_lock.lock();
    defer io_lock.unlock();

    return do_request(VIRTIO_BLK_T_IN, sector, buf);

}

/// Write one 512-byte sector to the block device. Returns true on success.
pub fn write_sector(sector: u64, buf: [*]const u8) bool {

    if (!initialized) return false;

    io_lock.lock();
    defer io_lock.unlock();

    return do_request(VIRTIO_BLK_T_OUT, sector, @constCast(buf));

}

/// Submit a block request and poll for completion.
fn do_request(req_type: u32, sector: u64, buf: [*]u8) bool {

    // Clear any stale interrupt from a previous request
    const pending = mmio_read(REG_INTERRUPT_STATUS);
    if (pending != 0) mmio_write(REG_INTERRUPT_ACK, pending);

    // Set up the request header
    req_header = .{

        .req_type = req_type,
        .reserved = 0,
        .sector = sector,

    };

    req_status = 0xFF; // sentinel

    // Descriptor 0: request header (device reads)
    vring.desc[0] = .{

        .addr = @intFromPtr(&req_header),
        .len = @sizeOf(VirtioBlkReq),
        .flags = VRING_DESC_F_NEXT,
        .next = 1,

    };

    // Descriptor 1: data buffer
    vring.desc[1] = .{

        .addr = @intFromPtr(buf),
        .len = SECTOR_SIZE,
        .flags = if (req_type == VIRTIO_BLK_T_IN)
            (VRING_DESC_F_WRITE | VRING_DESC_F_NEXT) // device writes data
        else
            VRING_DESC_F_NEXT, // device reads data
        .next = 2,

    };

    // Descriptor 2: status byte (device writes)
    vring.desc[2] = .{

        .addr = @intFromPtr(&req_status),
        .len = 1,
        .flags = VRING_DESC_F_WRITE,
        .next = 0,

    };

    // Make descriptor chain visible to device
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Add to available ring
    const avail_idx_ptr = @as(*volatile u16, @ptrCast(&vring.avail.idx));
    vring.avail.ring[avail_idx_ptr.* % QUEUE_SIZE] = 0;
    asm volatile ("dsb sy" ::: .{ .memory = true });
    avail_idx_ptr.* = avail_idx_ptr.* +% 1;
    asm volatile ("dsb sy" ::: .{ .memory = true });

    // Notify device (queue 0)
    mmio_write(REG_QUEUE_NOTIFY, 0);

    // Poll for completion via volatile read of used.idx
    const used_idx_ptr = @as(*volatile u16, @ptrCast(&vring.used.idx));
    var timeout: usize = 0;

    while (timeout < 1_000_000) : (timeout += 1) {

        asm volatile ("dsb sy" ::: .{ .memory = true });

        if (used_idx_ptr.* != last_used_idx) {

            last_used_idx = used_idx_ptr.*;

            const status = mmio_read(REG_INTERRUPT_STATUS);
            if (status != 0) mmio_write(REG_INTERRUPT_ACK, status);

            return req_status == 0;

        }

    }

    return false;

}

/// Check if the block device is available.
pub fn is_available() bool {

    return initialized;

}
