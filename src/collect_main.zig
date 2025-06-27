const std = @import("std");
const DocumentScope = @import("DocumentScope.zig");
const Ast = std.zig.Ast;

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

fn printTopLevelSymbols(allocator: std.mem.Allocator, file_path: []const u8) !void {
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const stat = try file.stat();
    const buffer = try allocator.alloc(u8, stat.size + 1);
    defer allocator.free(buffer);
    _ = try file.readAll(buffer[0..stat.size]);
    buffer[stat.size] = 0; // null-terminate
    var tree = try Ast.parse(allocator, buffer[0..stat.size :0], .zig);
    defer tree.deinit(allocator);

    var doc_scope = try DocumentScope.init(allocator, tree);
    defer doc_scope.deinit(allocator);

    const offsets_mod = @import("offsets.zig");

    // Print all top-level declarations (root scope)
    const root_scope = DocumentScope.Scope.Index.root;
    for (doc_scope.getScopeDeclarationsConst(root_scope)) |decl_index| {
        const decl = doc_scope.declarations.get(@intFromEnum(decl_index));
        const name = doc_scope.declaration_lookup_map.keys()[@intFromEnum(decl_index)].name;
        if (decl == .ast_node) {
            const node = decl.ast_node;
            const loc = offsets_mod.nodeToLoc(tree, node);
            const pos = offsets_mod.indexToPosition(buffer[0..stat.size], loc.start, .@"utf-8");
            // VSCode and most terminals expect 1-based line/column
            try std.io.getStdOut().writer().print("{s}:{d}:{d}: {s}: {any}\n", .{ file_path, pos.line + 1, pos.character + 1, name, decl });
        } else {
            // fallback for non-ast_node declarations
            try std.io.getStdOut().writer().print("{s}:?:?: {s}: {any}\n", .{ file_path, name, decl });
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
        printTopLevelSymbols(gpa, file) catch |err| {
            std.debug.print("  [error: {}]\n", .{err});
        };
    }
    return 0;
}
