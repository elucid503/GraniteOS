// build.zig - GraniteOS: zig build | zig build qemu | zig build qemu-debug

const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .aarch64,
        .os_tag   = .freestanding,
        .abi      = .none,

    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{

        .root_source_file = b.path("kernel/kmain.zig"),
        .target           = target,
        .optimize         = optimize,
        .single_threaded  = true,

    });

    kernel_module.addAssemblyFile(b.path("boot/start.S"));
    kernel_module.addAssemblyFile(b.path("boot/vectors.S"));

    const kernel = b.addExecutable(.{

        .name        = "kernel",
        .root_module = kernel_module,

    });

    kernel.setLinkerScript(b.path("boot/linker.ld"));

    b.installArtifact(kernel);

    // Shared QEMU flags

    const qemu_base = [_][]const u8{

        "qemu-system-aarch64",
        "-machine", "virt",
        "-cpu",     "cortex-a57",
        "-m",       "256M",
        "-display", "none",
        "-serial",  "stdio",
        "-kernel",  "zig-out/bin/kernel",

    };

    const qemu_cmd = b.addSystemCommand(&qemu_base);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const qemu_step = b.step("qemu", "Run kernel in QEMU");
    qemu_step.dependOn(&qemu_cmd.step);

    // GDB support: gdb-multiarch zig-out/bin/kernel → target remote :1234 → set arch aarch64

    const qemu_debug_cmd = b.addSystemCommand(&(qemu_base ++ [_][]const u8{ "-s", "-S" }));
    qemu_debug_cmd.step.dependOn(b.getInstallStep());

    const qemu_debug_step = b.step("qemu-debug", "Run kernel in QEMU with GDB stub on :1234 (halted)");
    qemu_debug_step.dependOn(&qemu_debug_cmd.step);

}
