const std = @import("std");
const lsp = @import("lsp");
const log = std.log.scoped(.server);

pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: ?lsp.AnyTransport = null,
    status: Status = .uninitialized,

    pub const Status = enum {
        uninitialized,
        initializing,
        initialized,
        shutdown,
        exiting_success,
        exiting_failure,
    };

    pub fn create(allocator: std.mem.Allocator) !*Server {
        const server = try allocator.create(Server);
        server.* = .{
            .allocator = allocator,
            .transport = null,
            .status = .uninitialized,
        };
        return server;
    }

    pub fn destroy(server: *Server) void {
        server.allocator.destroy(server);
    }

    pub fn setTransport(server: *Server, transport: lsp.AnyTransport) void {
        server.transport = transport;
    }

    pub fn loop(server: *Server) !void {
        std.debug.assert(server.transport != null);
        while (server.status != .exiting_success and server.status != .exiting_failure) {
            const json_message = try server.transport.?.readJsonMessage(server.allocator);
            defer server.allocator.free(json_message);
            log.info("TODO: handle LSP message: {s}", .{json_message});
            // Here you would parse and dispatch LSP messages
        }
    }
};
