// kernel/registry.zig - Program metadata for help and discovery

pub const Entry = struct {

    name: []const u8,
    description: []const u8,
    category: []const u8,
    listed: bool,

};

pub const programs: []const Entry = &.{

    // Shell and system

    .{ .name = "basalt", .description = "Interactive shell", .category = "global", .listed = true },
    .{ .name = "slate", .description = "System init process", .category = "global", .listed = false },

    // General utilities

    .{ .name = "help", .description = "List available programs", .category = "common", .listed = true },
    .{ .name = "about", .description = "About GraniteOS", .category = "common", .listed = true },
    .{ .name = "status", .description = "System status (scheduler | memory | disk)", .category = "common", .listed = true },
    .{ .name = "hello", .description = "Print a greeting", .category = "common", .listed = true },
    .{ .name = "echo", .description = "Print arguments to stdout", .category = "common", .listed = true },
    .{ .name = "clear", .description = "Clear the terminal screen", .category = "common", .listed = true },
    .{ .name = "cat", .description = "Copy stdin to stdout", .category = "common", .listed = true },
    .{ .name = "wc", .description = "Count lines and bytes from stdin", .category = "common", .listed = true },

    // Working directory (cd is a basalt built-in; path is also a built-in and a standalone program)

    .{ .name = "cd", .description = "Change working directory", .category = "location", .listed = true },
    .{ .name = "path", .description = "Print the working directory", .category = "location", .listed = true },

    // File system utilities

    .{ .name = "ls", .description = "List files (optional directory path)", .category = "fs", .listed = true },
    .{ .name = "mkdir", .description = "Create a directory", .category = "fs", .listed = true },
    .{ .name = "create", .description = "Create an empty file", .category = "fs", .listed = true },
    .{ .name = "delete", .description = "Delete a file or dir (-dir)", .category = "fs", .listed = true },
    .{ .name = "rename", .description = "Rename a file", .category = "fs", .listed = true },
    .{ .name = "view", .description = "Display file contents", .category = "fs", .listed = true },
    .{ .name = "edit", .description = "Edit file contents", .category = "fs", .listed = true },
    .{ .name = "own", .description = "Own a file", .category = "fs", .listed = true },

    // I/O utilities

    .{ .name = "diskformat", .description = "Wipe disk and reset file system", .category = "i/o", .listed = true },

    // Testers (unlisted)

    .{ .name = "fork_test", .description = "Fork and exec demo", .category = "testers", .listed = false },
    .{ .name = "pipe_test", .description = "Pipe IPC demo", .category = "testers", .listed = false },
    .{ .name = "sched_test", .description = "Scheduler demo", .category = "testers", .listed = false },
    .{ .name = "signal_test", .description = "Signal handling demo", .category = "testers", .listed = false },

};

/// Look up a program's registry entry by name.
pub fn find(name: []const u8) ?*const Entry {

    for (programs) |*entry| {

        if (entry.name.len != name.len) continue;

        var match = true;

        for (entry.name, name) |a, b| {

            if (a != b) {

                match = false;
                break;

            }

        }

        if (match) return entry;

    }

    return null;

}
