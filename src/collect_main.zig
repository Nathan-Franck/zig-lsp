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

const offsets_mod = @import("offsets.zig");

const SymbolInfo = struct {
    name: []const u8,
    line: usize,
    column: usize,
};

const MatchingSymbol = struct {
    name: []const u8,
    line: usize,
    column: usize,
    relative_path: []const u8,
    depth: usize,
};

const FileSymbols = struct {
    file_path: []const u8,
    symbols: std.ArrayList(SymbolInfo),
};

fn topLevelSymbols(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !FileSymbols {
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const stat = try file.stat();
    const buffer = try allocator.alloc(u8, stat.size + 1);
    _ = try file.readAll(buffer[0..stat.size]);
    buffer[stat.size] = 0; // null-terminate
    var tree = try Ast.parse(allocator, buffer[0..stat.size :0], .zig);
    defer tree.deinit(allocator);

    var doc_scope = try DocumentScope.init(allocator, tree);
    defer doc_scope.deinit(allocator);

    var symbols = std.ArrayList(SymbolInfo).init(allocator);
    const root_scope = DocumentScope.Scope.Index.root;
    for (doc_scope.getScopeDeclarationsConst(root_scope)) |decl_index| {
        const decl = doc_scope.declarations.get(@intFromEnum(decl_index));
        if (decl == .ast_node) {
            const name_token = decl.nameToken(tree);
            const name = offsets_mod.identifierTokenToNameSlice(tree, name_token);
            const node = decl.ast_node;
            const loc = offsets_mod.nodeToLoc(tree, node);
            const pos = offsets_mod.indexToPosition(buffer[0..stat.size], loc.start, .@"utf-8");
            try symbols.append(.{ .name = name, .line = pos.line + 1, .column = pos.character + 1 });
        }
    }
    return FileSymbols{
        .file_path = file_path,
        .symbols = symbols,
    };
}

pub fn main() !u8 {
    var gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) {
        std.debug.print("Usage: {s} <relative_path> <symbol_name>\n", .{args[0]});
        return 1;
    }
    const current_path = args[1];
    const symbol_name = args[2];

    var files = std.ArrayList([]const u8).init(gpa);
    defer {
        for (files.items) |file| gpa.free(file);
        files.deinit();
    }
    try collectZigFiles(gpa, ".", &files);

    var file_symbols = std.ArrayList(FileSymbols).init(gpa);
    defer {
        for (file_symbols.items) |fs| fs.symbols.deinit();
        file_symbols.deinit();
    }
    for (files.items) |file| {
        const fs = topLevelSymbols(gpa, file) catch |err| {
            std.debug.print("[error: {}] {s}\n", .{ err, file });
            continue;
        };
        try file_symbols.append(fs);
    }

    var matching_symbols = std.ArrayList(MatchingSymbol).init(gpa);
    defer matching_symbols.deinit();

    for (file_symbols.items) |fs| {
        for (fs.symbols.items) |sym| {
            if (std.mem.eql(u8, sym.name, symbol_name)) {
                const relative_path = try std.fs.path.relative(gpa, current_path, fs.file_path);

                var depth: usize = 0;
                for (relative_path) |c| {
                    if (c == std.fs.path.sep) depth += 1;
                }

                try matching_symbols.append(.{
                    .name = sym.name,
                    .line = sym.line,
                    .column = sym.column,
                    .relative_path = relative_path,
                    .depth = depth,
                });
            }
        }
    }

    std.mem.sort(MatchingSymbol, matching_symbols.items, {}, struct {
        fn lessThan(_: void, a: MatchingSymbol, b: MatchingSymbol) bool {
            return a.depth < b.depth;
        }
    }.lessThan);

    for (matching_symbols.items) |sym| {
        std.io.getStdOut().writer().print("{s}:{d}:{d} --- {s}\n", .{ sym.relative_path, sym.line, sym.column, sym.name }) catch {};
        gpa.free(sym.relative_path);
    }
    return 0;
}
