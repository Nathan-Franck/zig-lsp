const std = @import("std");
const lsp = @import("lsp");
const Server = @import("Server.zig").Server;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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
