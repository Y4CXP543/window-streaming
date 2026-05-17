const std = @import("std");
const builtin = @import("builtin");
const janus = @import("janus_client.zig");
const openport = @import("open_port.zig");

const win = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("/usr/x86_64-w64-mingw32/include/windows.h");
    } else {
        @cInclude("Windows.h");
    }
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var WINDOW_PROCESS: std.AutoHashMap(u64, *std.process.Child) = .init(allocator);
var WINDOW_PORT: std.AutoHashMap(u64, usize) = .init(allocator);

var portservice: ?*openport.PortService = null;
var janus_instance: ?*janus.JanusClient = null;

fn ffmpeg_process(window_id: usize, port: usize) !void {
    const rtp_base = "rtp://127.0.0.1:{}";
    var rtp_buf: [rtp_base.len + 5]u8 = undefined; //5 chars = max port = 65535
    const rtp_addr: []u8 = try std.fmt.bufPrint(&rtp_buf, "rtp://127.0.0.1:{}", .{port});

    const max_usize_len = 20;
    var window_id_buff: [max_usize_len]u8 = undefined;
    const window_id_str: []u8 = try std.fmt.bufPrint(&window_id_buff, "{}", .{window_id});

    var child = std.process.Child.init(&.{ "ffmpeg", "-f", "x11grab", "-window_id", window_id_str, "-i", ":1", "-payload_type", "96", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-vcodec", "libx264", "-x264-params", "keyint=25:min-keyint=25:scenecut=0:repeat-headers=1", "-g", "20", "-preset", "ultrafast", "-profile:v", "baseline", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-f", "rtp", rtp_addr }, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Ignore;
    child.stderr_behavior = std.process.Child.StdIo.Ignore;
    child.stdin_behavior = std.process.Child.StdIo.Ignore;

    try child.spawn();
    std.debug.print("Spawned child process!\n", .{});

    try WINDOW_PROCESS.put(window_id, &child);
    try WINDOW_PORT.put(window_id, port);
}

fn kill_process(window_id: usize) !void {
    if (WINDOW_PROCESS.get(window_id)) |child| {
        var ch: *std.process.Child = @constCast(child);
        _ = ch.kill() catch {};
        _ = WINDOW_PROCESS.remove(window_id);
    }
}

fn spawn_ffmpeg(_: win.HWINEVENTHOOK, _: win.DWORD, hwnd: win.HWND, _: win.LONG, _: win.LONG, _: win.DWORD, _: win.DWORD) callconv(.c) void {
    if (hwnd != null) {
        std.debug.print("result: {}", .{win.IsWindowVisible(hwnd)});
        if (win.IsWindowVisible(hwnd) != 0) {
            std.debug.print("hwnd\n", .{});
            var buf: [64]u8 = undefined;
            _ = win.GetWindowTextA(hwnd, &buf, buf.len);
            const expected = "Firefox";
            const window_id = @intFromPtr(hwnd);
            const exeName = hwndExeName(hwnd) catch "UNKNOWN";
            std.debug.print("exe name: {s}\n", .{exeName});

            std.debug.print("Handled window {s} \n", .{buf});

            if (std.mem.indexOf(u8, &buf, expected) != null) {
                if (portservice) |ps| {
                    if (janus_instance) |ji| {
                        const openedPort = ps.get();
                        std.debug.print("Starting ffmpeg process port {}\n", .{openedPort});
                        ffmpeg_process(window_id, openedPort) catch {
                            std.log.debug("Unable spawn ffmpeg process", .{});
                        };
                        std.debug.print("Started ffmpeg process!\n", .{});

                        std.debug.print("Initializing janus stream {}\n", .{openedPort});
                        ji.startStream(openedPort, &buf) catch {
                            std.log.debug("Unable register janus stream", .{});
                        };
                        std.debug.print("Initialized janus stream!\n", .{});
                    }
                }
            }
        }
    }
}

fn close_ffmpeg(_: win.HWINEVENTHOOK, _: win.DWORD, hwnd: win.HWND, _: win.LONG, _: win.LONG, _: win.DWORD, _: win.DWORD) callconv(.c) void {
    if (hwnd != null) {
        var buf: [256]u8 = undefined;
        _ = win.GetWindowTextA(hwnd, &buf, buf.len);
        const expected = "Firefox";
        const window_id = @intFromPtr(hwnd);
        std.log.info("Close object buf={s}\n", .{buf});
        if (std.mem.indexOf(u8, &buf, expected) != null) {
            std.log.info("hwnd=0x{x}\n", .{window_id});
            kill_process(window_id) catch {};
        }

        if (WINDOW_PORT.get(window_id)) |port| {
            if (portservice) |ps| {
                ps.release(port) catch {};
            }
            _ = WINDOW_PORT.remove(window_id);
        }
    }
}

pub fn hwndExeName(hwnd: win.HWND) ![]const u8 {
    var pid: u32 = 0;
    _ = win.GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0)
        return error.InvalidWindow;

    const process = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return error.OpenProcessFailed;
    defer _ = win.CloseHandle(process);
    var buffer: [win.MAX_PATH]u16 = undefined;
    var size: u32 = buffer.len;

    if (win.QueryFullProcessImageNameW(process, 0, &buffer, &size) == 0)
        return error.QueryFailed;

    const utf8_path = try std.unicode.utf16LeToUtf8Alloc(
        allocator,
        buffer[0..size],
    );

    return std.fs.path.basename(utf8_path);
}

pub fn windowListener(port_service_opaque: *anyopaque, janus_instance_opaque: *anyopaque) !void {
    portservice = @ptrCast(@alignCast(port_service_opaque));
    janus_instance = @ptrCast(@alignCast(janus_instance_opaque));

    _ = win.SetWinEventHook(win.EVENT_OBJECT_CREATE, win.EVENT_OBJECT_CREATE, null, &spawn_ffmpeg, 0, 0, win.WINEVENT_OUTOFCONTEXT | win.WINEVENT_SKIPOWNPROCESS);
    _ = win.SetWinEventHook(win.EVENT_OBJECT_END, win.EVENT_OBJECT_END, null, &close_ffmpeg, 0, 0, win.WINEVENT_OUTOFCONTEXT | win.WINEVENT_SKIPOWNPROCESS);

    var msg: win.MSG = undefined;
    while (win.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageA(&msg);
    }
}
