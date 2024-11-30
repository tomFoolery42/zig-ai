const std = @import("std");
const OpenAI = @import("openai.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get API key from environment
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    const api_key = env.get("OPENAI_API_KEY") orelse {
        std.debug.print("OPENAI_API_KEY environment variable not set\n", .{});
        return;
    };

    // Initialize OpenAI client
    var openai = try OpenAI.Client.init(allocator, api_key, null);

    const stdin = std.io.getStdIn().reader();
    var buf_reader = std.io.bufferedReader(stdin);
    const reader = buf_reader.reader();

    const stdout = std.io.getStdOut().writer();
    var buf_writer = std.io.bufferedWriter(stdout);
    const writer = buf_writer.writer();

    var buffer: [1024]u8 = undefined;

    var messages = std.ArrayList(OpenAI.Message).init(allocator);
    try messages.append(.{
        .role = "system",
        .content = "You are a helpful assistant",
    });

    while (true) {
        try writer.writeAll("> ");
        try buf_writer.flush();

        if (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            const user_message = .{
                .role = "user",
                .content = try allocator.dupe(u8, line),
            };
            try messages.append(user_message);

            const payload = OpenAI.ChatPayload{
                .model = "gpt-4o",
                .messages = messages.items,
                .max_tokens = 1000,
                .temperature = 0.2,
            };

            const parsedCompletion = try openai.chat(payload, true);
            defer parsedCompletion.deinit();
            const completion = parsedCompletion.value;

            try messages.append(
                OpenAI.Message{
                    .role = "assistant",
                    .content = try allocator.dupe(u8, completion.choices[0].message.content),
                },
            );

            if (completion.choices.len > 0) {
                try writer.print("{s}\n", .{completion.choices[0].message.content});
                try buf_writer.flush();
            }
        } else {
            break; // EOF reached
        }
    }
}
