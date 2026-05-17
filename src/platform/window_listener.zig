const builtin = @import("builtin");
const std = @import("std");
const janus = @import("janus_client.zig");
const openport = @import("open_port.zig");

pub fn subscriteToEvents() !void {
    const platform = switch (builtin.os.tag) {
        .windows => @import("windows.zig"),
        .linux => @import("linux.zig"),
        else => @compileError("Unsupported platform"),
    };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const base_url = "http://1.janus:8088";
    var port_service = openport.PortService.init(100, 5000);
    var janus_client = janus.JanusClient.init(allocator, base_url);

    try platform.windowListener(
        @ptrCast(&port_service),
        @ptrCast(&janus_client),
    );
}
