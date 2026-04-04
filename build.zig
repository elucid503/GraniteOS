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

    const qemu_flags = [_][]const u8{

        "qemu-system-aarch64",
        "-machine", "virt",
        "-cpu",     "cortex-a57",
        "-m",       "256M",
        "-display", "none",
        "-serial",  "stdio",
        "-kernel",  "zig-out/bin/kernel",

    };

    // When running inside a Flatpak sandbox (e.g. Zed), host binaries are not
    // on PATH. Fix is to wrap with flatpak-spawn --host so QEMU runs on the host system.

    var qemu_argv = std.ArrayList([]const u8).init(b.allocator);
    defer qemu_argv.deinit();

    if (std.process.getEnvVarOwned(b.allocator, "FLATPAK_ID") catch null) |id| {

        b.allocator.free(id);
        qemu_argv.appendSlice(&[_][]const u8{ "flatpak-spawn", "--host" }) catch unreachable;

    }

    qemu_argv.appendSlice(&qemu_flags) catch unreachable;

    const qemu_cmd = b.addSystemCommand(qemu_argv.items);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const qemu_step = b.step("qemu", "Run kernel in QEMU");
    qemu_step.dependOn(&qemu_cmd.step);

    // GDB support: gdb-multiarch zig-out/bin/kernel -> target remote :1234 -> set arch aarch64

    qemu_argv.appendSlice(&[_][]const u8{ "-s", "-S" }) catch unreachable;

    const qemu_debug_cmd = b.addSystemCommand(qemu_argv.items);
    qemu_debug_cmd.step.dependOn(b.getInstallStep());

    const qemu_debug_step = b.step("qemu-debug", "Run kernel in QEMU with GDB stub on :1234 (halted)");
    qemu_debug_step.dependOn(&qemu_debug_cmd.step);

}
