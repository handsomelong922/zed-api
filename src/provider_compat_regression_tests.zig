const std = @import("std");
const providers = @import("providers.zig");

fn providerRequest(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    if (parsed.value != .object or parsed.value.object.get("provider_request") == null) {
        parsed.deinit();
        return error.InvalidPayload;
    }
    return parsed;
}

test "GPT 5.6 native Responses omits unsupported temperature" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-luna","stream":true,"input":"ping","temperature":0.7}
    ;
    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expect(request.get("temperature") == null);
}

test "Claude Sonnet 5 OpenAI compatibility omits deprecated temperature" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","stream":true,"temperature":0.7,"messages":[{"role":"user","content":"ping"}]}
    ;
    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expect(request.get("temperature") == null);
}

test "Claude Sonnet 5 native Anthropic omits deprecated temperature" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","stream":true,"max_tokens":128,"temperature":0.7,"messages":[{"role":"user","content":"ping"}]}
    ;
    const payload = try providers.buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expect(request.get("temperature") == null);
}

test "native Anthropic tool_result defaults missing is_error to false" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","max_tokens":256,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"lookup","input":{"q":"x"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}]}
    ;
    const payload = try providers.buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    const messages = request.get("messages").?.array;
    const content = messages.items[1].object.get("content").?.array;
    const tool_result = content.items[0].object;
    const is_error = tool_result.get("is_error") orelse return error.MissingIsError;
    try std.testing.expect(is_error == .bool);
    try std.testing.expect(!is_error.bool);
}

test "native Anthropic tool_result preserves explicit is_error true" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","max_tokens":256,"messages":[{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"lookup","input":{"q":"x"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"failed"}]}]}
    ;
    const payload = try providers.buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    const messages = request.get("messages").?.array;
    const content = messages.items[1].object.get("content").?.array;
    const tool_result = content.items[0].object;
    const is_error = tool_result.get("is_error") orelse return error.MissingIsError;
    try std.testing.expect(is_error == .bool);
    try std.testing.expect(is_error.bool);
}

test "OpenAI tool result routed to Sonnet 5 gets is_error false" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"claude-sonnet-5","messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"x\"}"}}]},{"role":"tool","tool_call_id":"call_1","content":"ok"}]}
    ;
    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try providerRequest(allocator, payload);
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    const messages = request.get("messages").?.array;
    const content = messages.items[1].object.get("content").?.array;
    const tool_result = content.items[0].object;
    const is_error = tool_result.get("is_error") orelse return error.MissingIsError;
    try std.testing.expect(is_error == .bool);
    try std.testing.expect(!is_error.bool);
}
