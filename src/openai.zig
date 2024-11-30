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

pub const StreamResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []Choice,
    usage: Usage,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
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
    alloc: Allocator,
    request: std.http.Client.Request,
    buffer: [2048]u8 = undefined,

    pub fn init(alloc: Allocator, request: std.http.Client.Request) StreamReader {
        return .{
            .alloc = alloc,
            .request = request,
        };
    }

    pub fn deinit(self: *StreamReader) void {
        self.request.deinit();
    }

    // Read the next JSON response from the stream
    pub fn next(self: *StreamReader) !?StreamResponse {
        const line = (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) orelse return null;

        if (line.len == 0) return null;

        // Handle SSE format
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line["data: ".len..];

            // Skip heartbeat
            if (std.mem.eql(u8, data, "[DONE]")) return null;

            // Parse the JSON data
            const parsed = try std.json.parseFromSlice(StreamResponse, self.alloc, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

            return parsed.value;
        }

        return null;
    }
};

pub const ChatPayload = struct { model: []const u8, messages: []Message, max_tokens: ?u32, temperature: ?f32 };

const OpenAIError = error{
    BAD_REQUEST,
    UNAUTHORIZED,
    FORBIDDEN,
    NOT_FOUND,
    TOO_MANY_REQUESTS,
    INTERNAL_SERVER_ERROR,
    SERVICE_UNAVAILABLE,
    GATEWAY_TIMEOUT,
    UNKNOWN,
};

fn getError(status: std.http.Status) OpenAIError {
    const result = switch (status) {
        .bad_request => OpenAIError.BAD_REQUEST,
        .unauthorized => OpenAIError.UNAUTHORIZED,
        .forbidden => OpenAIError.FORBIDDEN,
        .not_found => OpenAIError.NOT_FOUND,
        .too_many_requests => OpenAIError.TOO_MANY_REQUESTS,
        .internal_server_error => OpenAIError.INTERNAL_SERVER_ERROR,
        .service_unavailable => OpenAIError.SERVICE_UNAVAILABLE,
        .gateway_timeout => OpenAIError.GATEWAY_TIMEOUT,
        else => OpenAIError.UNKNOWN,
    };
    return result;
}

pub const Client = struct {
    base_url: []const u8 = "https://api.openai.com/v1",
    api_key: []const u8,
    organization_id: ?[]const u8,
    alloc: Allocator,
    http_client: std.http.Client,

    pub fn init(alloc: Allocator, api_key: []const u8, organization_id: ?[]const u8) !Client {
        return Client{ .alloc = alloc, .api_key = api_key, .organization_id = organization_id, .http_client = std.http.Client{ .allocator = alloc } };
    }

    fn get_headers(alloc: std.mem.Allocator, api_key: []const u8) !std.http.Client.Request.Headers {
        const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        };
        return headers;
    }

    fn makeCall(self: *Client, uri: std.Uri, body: []const u8, _: bool) !std.http.Client.Request {
        const headers = try get_headers(self.alloc, self.api_key);
        defer self.alloc.free(headers.authorization.override);

        var buf: [16 * 1024]u8 = undefined;
        var req = try self.http_client.open(.POST, uri, .{ .headers = headers, .server_header_buffer = &buf });

        req.transfer_encoding = .{ .content_length = body.len };

        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        return req;
    }

    pub fn streamChat(self: *Client, payload: ChatPayload, verbose: bool) !StreamReader {
        const uri = std.Uri.parse("https://api.openai.com/v1/chat/completions") catch unreachable;

        const options = .{
            .model = payload.model,
            .messages = payload.messages,
            .max_tokens = payload.max_tokens,
            .temperature = payload.temperature,
            .stream = true,
        };
        const body = try std.json.stringifyAlloc(self.alloc, options, .{});
        defer self.alloc.free(body);

        var req = try self.makeCall(uri, body, verbose);

        if (req.response.status != .ok) {
            defer req.deinit();
            return getError(req.response.status);
        }

        return StreamReader.init(self.alloc, req);
    }

    pub fn chat(self: *Client, payload: ChatPayload, verbose: bool) !std.json.Parsed(ChatResponse) {
        const uri = std.Uri.parse("https://api.openai.com/v1/chat/completions") catch unreachable;

        const body = try std.json.stringifyAlloc(self.alloc, payload, .{ .whitespace = .indent_2 });
        defer self.alloc.free(body);

        var req = try self.makeCall(uri, body, verbose);
        defer req.deinit();

        const response = try req.reader().readAllAlloc(self.alloc, 1024 * 8);
        defer self.alloc.free(response);

        const parsed = try std.json.parseFromSlice(ChatResponse, self.alloc, response, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        return parsed;
    }
};
