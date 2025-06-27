const std = @import("std");
const lsp = @import("lsp");
const Server = @import("Server.zig").Server;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        try std.io.getStdOut().writeAll("0.14.0\n");
        return 0;
    }

    var transport = lsp.ThreadSafeTransport(.{
        .ChildTransport = lsp.TransportOverStdio,
        .thread_safe_read = false,
        .thread_safe_write = true,
    }){ .child_transport = .init(std.io.getStdIn(), std.io.getStdOut()) };

    var server = try Server.create(allocator);
    defer server.destroy();
    server.setTransport(transport.any());

    try server.loop();
    return 0;
}
