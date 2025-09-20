const base64 = std.base64;
const std = @import("std");
const meta = @import("std").meta;
const log = std.log;

const Allocator = std.mem.Allocator;

pub const Usage = struct {
    prompt_tokens: u64,
    completion_tokens: ?u64,
    total_tokens: u64,
};

pub const Choice = struct { index: usize, finish_reason: ?[]const u8, message: struct { role: []const u8, content: []const u8 } };

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []Choice,
    usage: Usage,
};

pub const DeltaChoice = struct { index: usize, delta: struct { role: ?[]const u8 = null, content: ?[]const u8 = null } };
pub const StreamResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []DeltaChoice,
};

pub const Role = struct {
    pub const system = "system";
    pub const user = "user";
    pub const assistant = "assistant";
};

pub const Image = struct {
    const Content = struct {
        @"type":    []const u8,
        value:      []const u8,
    };

    alloc:      Allocator,
    role:       []const u8,
    content:    []Content,

    pub fn deinit(self: @This()) void {
        self.alloc.free(self.content[1].value);
        self.alloc.free(self.content);
    }
};

pub const Text = struct {
    role:       []const u8,
    content:    []const u8,

};

pub const Message = union(enum) {
    const Self = @This();
    Text: Text,
    Image: Image,

    pub fn deinit(self: Self) void {
        switch (self) {
            .Image => |i| {
                i.deinit();
            },
            else => {},
        }
    }

    pub fn image(alloc: Allocator, prompt: []const u8, file: std.fs.File) !Self {
        const image_data = try file.readToEndAlloc(alloc, (try file.stat()).size);
        defer alloc.free(image_data);
        const encoded_length: usize = @intCast(base64.standard.Encoder.calcSize(image_data.len));
        const encoded = try alloc.alloc(u8, encoded_length);
        defer alloc.free(encoded);
        _ = base64.standard.Encoder.encode(encoded, image_data);
        const image_url = try std.fmt.allocPrint(alloc, "data:image/jpeg;base64,{s}", .{encoded});
        const content_list = try alloc.alloc(Image.Content, 2);
        content_list[0] = .{.type = "text", .value = prompt};
        content_list[1] = .{.type = "image_url", .value = image_url};
        return .{.Image = .{
            .alloc = alloc,
            .role = Role.user,
            .content = content_list,
        }};
    }

    pub fn user(content: []const u8) Self {
        return .{.Text = .{
            .role = Role.user,
            .content = content,
        }};
    }

    pub fn system(content: []const u8) Self {
        return .{.Text = .{
            .role = Role.system,
            .content = content,
        }};
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        switch (self) {
            .Text => |text| {
                try jws.objectField("role");
                try jws.write(text.role);
                try jws.objectField("content");
                try jws.write(text.content);
            },
            .Image => |i| {
                try jws.objectField("role");
                try jws.write(Role.user);
                try jws.objectField("content");
                try jws.beginArray();
                for (i.content) |next| {
                    try jws.beginObject();
                    try jws.objectField("type");
                    try jws.write(next.type);
                    if (std.mem.eql(u8, next.type, "text")) {
                        try jws.objectField("text");
                        try jws.write(next.value);
                    }
                    else {
                        try jws.objectField("image_url");
                        try jws.write(next.value);
                    }
                    try jws.endObject();
                }
                try jws.endArray();
            },
        }
        try jws.endObject();
    }
};

pub const Model = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    owned_by: []const u8,
};

pub const ModelResponse = struct {
    object: []const u8,
    data: []Model,
};

const StreamReader = struct {
    arena: std.heap.ArenaAllocator,
    request: std.http.Client.Request,
    buffer: [2048]u8 = undefined,

    pub fn init(request: std.http.Client.Request) !StreamReader {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .request = request,
        };
    }

    pub fn deinit(self: *StreamReader) void {
        self.arena.deinit();
        self.request.deinit();
    }

    pub fn next(self: *StreamReader) !?StreamResponse {
        const line = (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) orelse return null;
        try self.request.reader().skipBytes(1, .{}); // Skip second newline

        if (line.len == 0) return null;

        // Handle SSE format
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line["data: ".len..];

            if (std.mem.eql(u8, data, "[DONE]")) return null;

            const parsed = try std.json.parseFromSlice(StreamResponse, self.arena.allocator(), data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

            return parsed.value;
        }

        return null;
    }
};

pub const ChatPayload = struct { model: []const u8, messages: []const Message, max_tokens: ?u32, temperature: ?f32 };

const OpenAIError = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    TooManyRequests,
    InternalServerError,
    ServiceUnavailable,
    GatewayTimeout,
    Unknown,
};

fn getError(status: std.http.Status) OpenAIError {
    const result = switch (status) {
        .bad_request => OpenAIError.BadRequest,
        .unauthorized => OpenAIError.Unauthorized,
        .forbidden => OpenAIError.Forbidden,
        .not_found => OpenAIError.NotFound,
        .too_many_requests => OpenAIError.TooManyRequests,
        .internal_server_error => OpenAIError.InternalServerError,
        .service_unavailable => OpenAIError.ServiceUnavailable,
        .gateway_timeout => OpenAIError.GatewayTimeout,
        else => OpenAIError.Unknown,
    };
    return result;
}

pub const Client = struct {
    base_url: []const u8,
    api_key: []const u8,
    organization_id: ?[]const u8,
    allocator: Allocator,
    http_client: std.http.Client,

    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, base_url: ?[]const u8, api_key: ?[]const u8, organization_id: ?[]const u8) !Client {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        const _api_key = api_key orelse env.get("OPENAI_API_KEY") orelse "";
        const openai_api_key = try allocator.dupe(u8, _api_key);
        const _url = base_url orelse "https://api.openai.com/v1";
        const url = try allocator.dupe(u8, _url);

        var arena = std.heap.ArenaAllocator.init(allocator); // Initialize arena
        errdefer arena.deinit(); // Ensure arena is deinitialized on error

        var http_client = std.http.Client{ .allocator = allocator };
        http_client.initDefaultProxies(arena.allocator()) catch |err| {
            http_client.deinit();
            return err;
        };

        return Client{
            .base_url = url,
            .allocator = allocator,
            .api_key = openai_api_key,
            .organization_id = organization_id,
            .http_client = http_client,
            .arena = arena,
        };
    }

    fn get_headers(alloc: std.mem.Allocator, api_key: []const u8) !std.http.Client.Request.Headers {
        const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        };
        return headers;
    }

    fn makeCall(self: *Client, endpoint: []const u8, body: []const u8, _: bool) !std.http.Client.Request {
        const headers = try get_headers(self.allocator, self.api_key);
        defer self.allocator.free(headers.authorization.override);

        const path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(path);
        const uri = try std.Uri.parse(path);

        var req = try self.http_client.request(.POST, uri, .{ .keep_alive = false, .headers = headers});

        req.transfer_encoding = .chunked;
        try req.sendBodyComplete(@constCast(body));

        return req;
    }

    /// Makes a streaming chat completion request to the OpenAI API.
    /// Returns a StreamReader that can be used to read the response chunks.
    /// Caller must call deinit() on the returned StreamReader when done.
    pub fn streamChat(self: *Client, payload: ChatPayload, verbose: bool) !StreamReader {
        const options = .{
            .model = payload.model,
            .messages = payload.messages,
            .max_tokens = payload.max_tokens,
            .temperature = payload.temperature,
            .stream = true,
        };
        const body = try std.json.stringifyAlloc(self.allocator, options, .{});
        defer self.allocator.free(body);

        var req = try self.makeCall("/chat/completions", body, verbose);

        if (req.response.status != .ok) {
            const err = getError(req.response.status);
            req.deinit();
            return err;
        }

        return StreamReader.init(req);
    }

    /// Makes a chat completion request to the OpenAI API.
    /// Caller owns the returned memory and must call deinit() on the result.
    pub fn chat(self: *Client, payload: ChatPayload, verbose: bool) !std.json.Parsed(ChatResponse) {
        const options = .{
            .model = payload.model,
            .messages = payload.messages,
            .max_tokens = payload.max_tokens,
            .temperature = payload.temperature,
        };
        const body = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(options, .{})});
        defer self.allocator.free(body);

        var req = try self.makeCall("/chat/completions", body, verbose);
        defer req.deinit();

        var response_status = try req.receiveHead(&.{});
        if (response_status.head.status != .ok) {
            const err = getError(response_status.head.status);
            req.deinit();
            return err;
        }

        const response = try response_status.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(response);

        const parsed = try std.json.parseFromSlice(ChatResponse, self.allocator, response, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        return parsed;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        if (self.organization_id) |org_id| {
            self.allocator.free(org_id);
        }
        self.http_client.deinit();
        self.arena.deinit();
    }
};
