const std = @import("std");

pub const Kind = enum { not_status, event, queued, started, failed, stream_ended, unknown_status };

pub const Parsed = struct {
    kind: Kind,
    code: ?[]u8 = null,
    message: ?[]u8 = null,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        self.code = null;
        self.message = null;
    }
};

fn copyString(allocator: std.mem.Allocator, value: ?std.json.Value) ?[]u8 {
    const item = value orelse return null;
    if (item != .string) return null;
    return allocator.dupe(u8, item.string) catch null;
}

/// Zed's `/completions` stream is `CompletionEvent<T>`: provider events are
/// wrapped in `event`, while queue/start/failure/completion transport state is
/// wrapped in `status`. Keep the control plane out of downstream SSE.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) Parsed {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch
        return .{ .kind = .not_status };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .kind = .not_status };

    if (parsed.value.object.get("event") != null) return .{ .kind = .event };
    const status = parsed.value.object.get("status") orelse return .{ .kind = .not_status };

    if (status == .string) {
        if (std.mem.eql(u8, status.string, "started")) return .{ .kind = .started };
        if (std.mem.eql(u8, status.string, "stream_ended")) return .{ .kind = .stream_ended };
        return .{ .kind = .unknown_status };
    }

    if (status != .object) return .{ .kind = .unknown_status };
    if (status.object.get("queued") != null) return .{ .kind = .queued };
    if (status.object.get("failed")) |failed| {
        if (failed != .object) return .{ .kind = .failed };
        return .{
            .kind = .failed,
            .code = copyString(allocator, failed.object.get("code")),
            .message = copyString(allocator, failed.object.get("message")),
        };
    }
    return .{ .kind = .unknown_status };
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

/// Convert a safe Zed completion failure code/message into the scheduler's
/// HTTP-like status buckets. Unknown provider failures remain transient 502s.
pub fn suggestedHttpStatus(info: Parsed) u16 {
    if (info.code) |code| {
        if (containsAny(code, &.{ "429", "rate_limit", "rate_limited" })) return 429;
        if (containsAny(code, &.{ "401", "unauthorized", "expired_token", "outdated_token" })) return 401;
        if (containsAny(code, &.{ "403", "forbidden", "trial_blocked" })) return 403;
        if (containsAny(code, &.{ "402", "payment_required" })) return 402;
    }
    if (info.message) |message| {
        if (std.mem.indexOf(u8, message, "429") != null) return 429;
        if (std.mem.indexOf(u8, message, "401") != null) return 401;
        if (std.mem.indexOf(u8, message, "403") != null) return 403;
    }
    return 502;
}


test "completion status parser distinguishes control messages from model events" {
    const allocator = std.testing.allocator;

    var started = parseLine(allocator, "{\"status\":\"started\"}");
    defer started.deinit(allocator);
    try std.testing.expectEqual(Kind.started, started.kind);

    var queued = parseLine(allocator, "{\"status\":{\"queued\":{\"position\":2}}}");
    defer queued.deinit(allocator);
    try std.testing.expectEqual(Kind.queued, queued.kind);

    var event = parseLine(allocator, "{\"event\":{\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}}");
    defer event.deinit(allocator);
    try std.testing.expectEqual(Kind.event, event.kind);

    var ended = parseLine(allocator, "{\"status\":\"stream_ended\"}");
    defer ended.deinit(allocator);
    try std.testing.expectEqual(Kind.stream_ended, ended.kind);
}

test "completion failed status preserves safe error details and status class" {
    const allocator = std.testing.allocator;
    var failed = parseLine(allocator, "{\"status\":{\"failed\":{\"code\":\"upstream_http_429\",\"message\":\"rate limited\",\"request_id\":\"abc\",\"retry_after\":1.0}}}");
    defer failed.deinit(allocator);
    try std.testing.expectEqual(Kind.failed, failed.kind);
    try std.testing.expectEqualStrings("upstream_http_429", failed.code.?);
    try std.testing.expectEqualStrings("rate limited", failed.message.?);
    try std.testing.expectEqual(@as(u16, 429), suggestedHttpStatus(failed));

    var trial = parseLine(allocator, "{\"status\":{\"failed\":{\"code\":\"trial_blocked\",\"message\":\"trial blocked\"}}}");
    defer trial.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), suggestedHttpStatus(trial));
}
