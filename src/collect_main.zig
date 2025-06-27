const std = @import("std");

fn collectZigFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            const sub_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(sub_path);
            try collectZigFiles(allocator, sub_path, files);
        } else if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.name, ".zig")) {
                const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
                try files.append(file_path);
            }
        }
    }
}

pub fn main() !u8 {
    var gpa = std.heap.page_allocator;
    var files = std.ArrayList([]const u8).init(gpa);
    defer {
        for (files.items) |file| gpa.free(file);
        files.deinit();
    }
    try collectZigFiles(gpa, ".", &files);
    for (files.items) |file| {
        try std.io.getStdOut().writer().print("{s}\n", .{file});
    }
    return 0;
}
