const std = @import("std");
const ws = @import("websocket");

const Allocator = std.mem.Allocator;
const Errors = error {
    BadRequest,
    WebsocketClosed,
};
const History = struct {
    outputs:  struct {
        finished_node: struct {
            images: []struct{
                filename: String,
                subfolder: String,
            },
        },
    },
};
const Image = String;
const Self = @This();
const String = []const u8;
const WebsocketResponse = struct {
    data: struct {
        status:  struct {
            exec_info: struct {
                queue_remaining: i64
            },
        },
        sid: String,
    },
};

alloc:  Allocator,
client: std.http.Client,
url:    String,

pub fn init(alloc: Allocator, url: String) !Self {
    var http_client = std.http.Client{ .allocator = alloc, .write_buffer_size = 8192 };
    http_client.initDefaultProxies(alloc) catch |err| {
            http_client.deinit();
            return err;
        };

    return .{
        .alloc = alloc,
        .client = http_client,
        .url = try alloc.dupe(u8, url),
    };
}

pub fn deinit(self: Self) void {
    self.alloc.free(self.url);
}

fn get_headers() !std.http.Client.Request.Headers {
        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/json" },
        };
        return headers;
    }

pub fn imageGenerate(self: *Self, json: String, args: anytype) !Image {
    _ = args;
    //const full_json = self.alloc.printAlloc();
    //defer self.alloc.free(full_json);
    const client_id: String = "59800f37-6230-418b-bf2e-3403261fa898";

    try self.imageQueue(json, client_id);

    try self.imageWait(client_id);

    return self.imageGet(client_id);
}

pub fn imageQueue(self: *Self, json: String, client_id: String) !void {
    const path = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ self.url, "/prompt" });
    defer self.alloc.free(path);
    const uri = try std.Uri.parse(path);
    const headers = try get_headers();

    const tmp = try std.fmt.allocPrint(self.alloc, "{{ \"prompt\": {s}, \"client_id\": \"{s}\" }}", .{json, client_id});
    defer self.alloc.free(tmp);

    var req = try self.client.request(.POST, uri, .{ .keep_alive = false, .headers = headers});
    try req.sendBodyComplete(@constCast(tmp));
    defer req.deinit();

    var buff: [1024 * 16]u8 = undefined;
    var response_status = try req.receiveHead(&buff);
    if (response_status.head.status != .ok) {
        std.debug.print("{d} bad status: {f}\n", .{response_status.head.status, std.json.fmt(response_status.head, .{})});
        return Errors.BadRequest;
    }

    const response = try response_status.reader(&.{}).allocRemaining(self.alloc, .unlimited);
    defer self.alloc.free(response);
    const raw = try std.json.parseFromSlice(std.json.Value, self.alloc, response, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer raw.deinit();
}

pub fn imageGet(self: *Self, client_id: String) !Image {
    const path = try std.fmt.allocPrint(self.alloc, "{s}/history?clientId={s}&max_items=1", .{self.url, client_id});
    defer self.alloc.free(path);
    const uri = try std.Uri.parse(path);
    const headers = try get_headers();

    var req = try self.client.request(.GET, uri, .{ .keep_alive = false, .headers = headers});
    try req.sendBodiless();
    defer req.deinit();

    var buff: [1024 * 8]u8 = undefined;
    var response_status = try req.receiveHead(&buff);
    if (response_status.head.status != .ok) {
        std.debug.print("{d} bad status: {f}\n", .{response_status.head.status, std.json.fmt(response_status.head, .{})});
        return Errors.BadRequest;
    }

    const response = try response_status.reader(&.{}).allocRemaining(self.alloc, .unlimited);
    defer self.alloc.free(response);
    std.debug.print("raw: {s}\n", .{response});
    const raw = try std.json.parseFromSlice(std.json.Value, self.alloc, response, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer raw.deinit();
    std.debug.print("history? {any}\n", .{raw.value});

    return "not ready yet";
}

pub fn imageWait(self: *Self, id: String) !void {
    var waiting = true;
    var websocket = try ws.Client.init(self.alloc, .{.port = 443, .host = "image.klein.home", .tls = true});
    defer {
        websocket.close(.{}) catch {};
        websocket.deinit();
    }
    // timeout is not what I think it is. Timeout for the handshake, not the connection
    const websocket_id = try std.fmt.allocPrint(self.alloc, "/ws?clientId={s}", .{id});
    defer self.alloc.free(websocket_id);
    try websocket.handshake(websocket_id, .{.timeout_ms = 5000, .headers = "Host: image.klein.home"});
    try websocket.readTimeout(std.time.ms_per_s * 15);

    while (waiting) {
        if (try websocket.read()) |response| {
            defer websocket.done(response);
            switch (response.type) {
                .text, .binary => {
                    std.debug.print("raw: {s}\n", .{response.data});
                    if (std.json.parseFromSlice(WebsocketResponse, self.alloc, response.data, .{.ignore_unknown_fields = true})) |parsed| {
                        defer parsed.deinit();
                        waiting = parsed.value.data.status.exec_info.queue_remaining != 0;
                    }
                    else |_| {
                        std.debug.print("non-status message\n", .{});
                    }
                    std.debug.print("still waiting: {}\n", .{waiting});
                },
                .ping => websocket.writePong(response.data) catch {},
                .pong => {},
                .close => {
                    std.log.err("athena: websocket closing?", .{});
                    return Errors.WebsocketClosed;
                },
            }
        }
    }
}
