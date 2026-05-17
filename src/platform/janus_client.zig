const std = @import("std");

const PluginData = struct {
    plugin: []const u8,
    data: Data,
};

const JanusError = struct {
    streaming: ?[]const u8 = null,
    error_code: ?usize = null,
    @"error": []const u8,
    reason: []const u8,
};

const Stream = struct { id: ?i64 };

const Data = struct {
    id: ?i64 = null,
    stream: ?Stream = null,
    streaming: ?[]const u8 = null,
    error_code: ?usize = null,
    @"error": ?[]const u8 = null,
};

pub const JanusResponse = struct { janus: []const u8, session_id: ?usize = null, transaction: []const u8, sender: ?usize = null, data: ?Data = null, pluginData: ?PluginData = null, @"error": ?JanusError = null };

pub const JanusClient = struct {
    base_url: []const u8,
    allocator: std.mem.Allocator,
    transaction_counter: std.atomic.Value(u32),
    mount_counter: std.atomic.Value(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, baseUrl: []const u8) Self {
        return .{ .base_url = baseUrl, .allocator = allocator, .transaction_counter = std.atomic.Value(u32).init(1), .mount_counter = std.atomic.Value(u32).init(1) };
    }

    fn executeRequest(self: *Self, uri: std.Uri, payload: []const u8) ![]const u8 {
        var client = std.http.Client{ .allocator = self.allocator };

        std.debug.print("Execute request {s}://{s}:{?}/{s} payload:\n{s}\n", .{ uri.scheme, uri.host.?.percent_encoded, uri.port, uri.path.percent_encoded, payload });

        var req = try client.request(.POST, uri, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        defer req.deinit();
        try req.sendBodyComplete(@constCast(payload));
        var buf: [0]u8 = undefined;
        var response = try req.receiveHead(&buf);
        if (response.head.status != .ok) {
            return error.NonOkResponse;
        }
        const result = try response.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        std.debug.print("Response {s}\n", .{result});

        return result;
    }

    pub fn createSession(self: *Self) !i64 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/janus", .{self.base_url});
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        const t_id = self.transaction_counter.fetchAdd(1, .seq_cst);
        const payload: []u8 = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "janus": "create",
            \\  "transaction": "t{}"
            \\}}
        , .{t_id});
        defer self.allocator.free(payload);

        const body = try self.executeRequest(uri, payload);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice(
            JanusResponse,
            self.allocator,
            body,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();
        const value: JanusResponse = parsed.value;
        if (value.data) |data| {
            if (data.id) |id| {
                return id;
            }
        }
        return 0;
    }

    fn attachToPlugin(self: *Self, session_id: i64, plugin: []const u8) !i64 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/janus/{}", .{ self.base_url, session_id });
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        const t_id = self.transaction_counter.fetchAdd(1, .seq_cst);
        const payload: []u8 = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "janus": "attach",
            \\  "plugin": "{s}",
            \\  "transaction": "t{}"
            \\}}
        , .{ plugin, t_id });
        defer self.allocator.free(payload);

        const body = try self.executeRequest(uri, payload);
        defer self.allocator.free(body);

        const parsed = try std.json.parseFromSlice(
            JanusResponse,
            self.allocator,
            body,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();
        const value: JanusResponse = parsed.value;
        if (value.data) |data| {
            if (data.id) |id| {
                return id;
            }
        }
        return 0;
    }

    // 3
    pub fn registerMountPoint(self: *Self, session_id: i64, handle_id: i64, port: usize, name: []const u8) !usize {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/janus/{}/{}", .{ self.base_url, session_id, handle_id });
        defer self.allocator.free(url);
        const uri = try std.Uri.parse(url);
        const m_id = self.mount_counter.fetchAdd(1, .seq_cst);
        const t_id = self.transaction_counter.fetchAdd(1, .seq_cst);
        const payload: []u8 = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "janus": "message",
            \\  "transaction": "t{}",
            \\  "body": {{
            \\      "request": "create",
            \\      "type": "rtp",
            \\      "id": {},
            \\      "name": "{s}",
            \\      "description": "{s}",
            \\      "video": true,
            \\      "videopt": 96,
            \\      "videocodec": "h264",
            \\      "videoport": {}
            \\}}
            \\}}
        , .{ t_id, m_id, name, name, port });
        defer self.allocator.free(payload);

        const body = try self.executeRequest(uri, payload);
        defer self.allocator.free(body);
        const parsed = try std.json.parseFromSlice(
            JanusResponse,
            self.allocator,
            body,
            .{
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();
        const value: JanusResponse = parsed.value;

        if (value.data) |data| {
            if (data.stream) |stream| {
                if (stream.id) |id| {
                    return @intCast(id);
                }
            }
        }
        return 0;
    }

    pub fn startStream(self: *Self, port: usize, name: []const u8) !void {
        const plugin = "janus.plugin.streaming";

        std.debug.print("Try to create session\n", .{});
        const session_id = try self.createSession();
        std.debug.print("Session created {}\n", .{session_id});

        std.debug.print("Creating handle\n", .{});
        const handle_id = try self.attachToPlugin(session_id, plugin);
        std.debug.print("Created handle {}\n", .{handle_id});

        std.debug.print("Registering mount point\n", .{});
        const mount_id = try self.registerMountPoint(session_id, handle_id, port, name);
        std.debug.print("Registered mount point {}\n", .{mount_id});
    }

    pub fn deleteSession() !usize {
        return 0;
    }

    pub fn deleteMountpoint() !usize {
        return 0;
    }
};
