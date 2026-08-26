#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:120]!r}")
    write(path, text.replace(old, new, 1))


def append_once(path: str, marker: str, text_to_append: str) -> None:
    text = read(path)
    if marker in text:
        return
    write(path, text.rstrip() + "\n\n" + text_to_append.strip() + "\n")


STATUS_STUB = r'''const std = @import("std");

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

pub fn parseLine(_: std.mem.Allocator, _: []const u8) Parsed {
    return .{ .kind = .not_status };
}

pub fn suggestedHttpStatus(_: Parsed) u16 {
    return 502;
}

'''

STATUS_TESTS = r'''
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
'''

STATUS_IMPL = r'''const std = @import("std");

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

'''

PROVIDER_TEST_MARKER = 'test "current native Responses moves developer/system input to top-level instructions"'
PROVIDER_TESTS = r'''
test "current native Responses moves developer/system input to top-level instructions" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-5.6-luna","stream":true,"instructions":"base instruction","input":[{"type":"message","role":"developer","content":[{"type":"input_text","text":"developer instruction"}]},{"type":"message","role":"system","content":"system instruction"},{"type":"message","role":"user","content":"ping"}]}
    ;
    const payload = try buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const request = parsed.value.object.get("provider_request").?.object;
    try std.testing.expectEqualStrings("base instruction\n\ndeveloper instruction\n\nsystem instruction", request.get("instructions").?.string);
    const input = request.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expectEqualStrings("user", input[0].object.get("role").?.string);
}

test "current Zed completion envelope omits legacy intent field" {
    const allocator = std.testing.allocator;
    const payload = try buildZedPayload(allocator, "{\"model\":\"gpt-5.6-luna\",\"input\":\"ping\"}", false);
    defer allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("intent") == null);
}
'''

STREAM_TEST_MARKER = 'test "Responses stream classifier rejects Zed control messages"'
STREAM_STUBS_AND_TESTS = r'''
const ResponsesEventClass = enum { none, event, terminal };

fn classifyResponsesEventLine(_: []const u8, _: std.mem.Allocator) ResponsesEventClass {
    return .none;
}

fn shouldSendResponsesDone(_: bool, _: bool, _: bool) bool {
    return false;
}

test "Responses stream classifier rejects Zed control messages" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ResponsesEventClass.none, classifyResponsesEventLine("{\"status\":\"started\"}", allocator));
    try std.testing.expectEqual(ResponsesEventClass.event, classifyResponsesEventLine("{\"event\":{\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}}", allocator));
    try std.testing.expectEqual(ResponsesEventClass.terminal, classifyResponsesEventLine("{\"event\":{\"type\":\"response.completed\",\"response\":{\"id\":\"r\"}}}", allocator));
}

test "Responses stream bridges Zed stream_ended only after real events" {
    try std.testing.expect(shouldSendResponsesDone(true, true, false));
    try std.testing.expect(!shouldSendResponsesDone(true, false, false));
    try std.testing.expect(!shouldSendResponsesDone(true, true, true));
    try std.testing.expect(!shouldSendResponsesDone(false, true, false));
}
'''

STREAM_IMPL_HELPERS = r'''
const ResponsesEventClass = enum { none, event, terminal };

fn classifyResponsesEventLine(line: []const u8, allocator: std.mem.Allocator) ResponsesEventClass {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return .none;
    defer parsed.deinit();
    if (parsed.value != .object) return .none;
    const event_value = parsed.value.object.get("event") orelse parsed.value;
    if (event_value != .object) return .none;
    const event_type = switch (event_value.object.get("type") orelse return .none) {
        .string => |value| value,
        else => return .none,
    };
    if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.failed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        return .terminal;
    }
    return .event;
}

fn shouldSendResponsesDone(is_responses: bool, got_any_data: bool, terminal_seen: bool) bool {
    return is_responses and got_any_data and !terminal_seen;
}
'''


def red_status() -> None:
    write("src/completion_status.zig", STATUS_STUB + STATUS_TESTS)


def green_status() -> None:
    write("src/completion_status.zig", STATUS_IMPL + STATUS_TESTS)


def red_providers() -> None:
    append_once("src/providers.zig", PROVIDER_TEST_MARKER, PROVIDER_TESTS)


def green_providers() -> None:
    path = "src/providers.zig"
    text = read(path)
    if 'const completion_status = @import("completion_status.zig");' not in text:
        text = text.replace('const std = @import("std");\n', 'const std = @import("std");\nconst completion_status = @import("completion_status.zig");\n', 1)

    old_envelope = 'try w.print("{{\\\"thread_id\\\":\\\"{s}\\\",\\\"prompt_id\\\":\\\"{s}\\\",\\\"intent\\\":\\\"user_prompt\\\",\\\"provider\\\":\\\"{s}\\\",\\\"model\\\":\\\"{s}\\\",\\\"provider_request\\\":{{", .{'
    new_envelope = 'try w.print("{{\\\"thread_id\\\":\\\"{s}\\\",\\\"prompt_id\\\":\\\"{s}\\\",\\\"provider\\\":\\\"{s}\\\",\\\"model\\\":\\\"{s}\\\",\\\"provider_request\\\":{{", .{'
    if old_envelope not in text:
        raise SystemExit("providers.zig: legacy completion envelope pattern not found")
    text = text.replace(old_envelope, new_envelope, 1)

    old_call = 'return buildNativeResponsesRequest(w, parsed, model, is_anthropic);'
    if old_call not in text:
        raise SystemExit("providers.zig: native Responses call pattern not found")
    text = text.replace(old_call, 'return buildNativeResponsesRequest(allocator, w, parsed, model, is_anthropic);', 1)

    helper_marker = 'fn writeNativeResponsesInput(w: *std.io.Writer, input: std.json.Value) !void {'
    if helper_marker not in text:
        raise SystemExit("providers.zig: writeNativeResponsesInput marker not found")
    helper_code = r'''fn isNativeResponsesInstructionItem(item: std.json.Value) bool {
    if (item != .object) return false;
    const role = switch (item.object.get("role") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return isSystemInstructionRole(role);
}

fn collectNativeResponsesInstructions(allocator: std.mem.Allocator, parsed: std.json.Value) !?[]u8 {
    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    var wrote_any = false;

    if (parsed.object.get("instructions")) |instructions| {
        if (instructions == .string and instructions.string.len > 0) {
            try buf.writer.writeAll(instructions.string);
            wrote_any = true;
        }
    }

    if (parsed.object.get("input")) |input| {
        if (input == .array) {
            for (input.array.items) |item| {
                if (!isNativeResponsesInstructionItem(item)) continue;
                const content = item.object.get("content") orelse continue;
                try appendContentText(&buf.writer, content, &wrote_any);
            }
        }
    }

    if (!wrote_any) {
        buf.deinit();
        return null;
    }
    return try buf.toOwnedSlice();
}

'''
    text = text.replace(helper_marker, helper_code + helper_marker, 1)

    skip_marker = '''                    if (std.mem.eql(u8, item_type, "additional_tools")) continue;\n                }\n                if (!first) try w.writeAll(",");'''
    skip_replacement = '''                    if (std.mem.eql(u8, item_type, "additional_tools")) continue;\n                }\n                if (isNativeResponsesInstructionItem(item)) continue;\n                if (!first) try w.writeAll(",");'''
    if skip_marker not in text:
        raise SystemExit("providers.zig: native Responses input skip marker not found")
    text = text.replace(skip_marker, skip_replacement, 1)

    old_role_rewrite = '''        if (std.mem.eql(u8, key, "role") and\n            entry.value_ptr.* == .string and\n            std.mem.eql(u8, entry.value_ptr.string, "developer"))\n        {\n            // Zed's hosted parser predates the Responses developer role. A\n            // system message preserves the instruction priority it supports.\n            try w.writeAll("\\\"system\\\"");\n        } else if (std.mem.eql(u8, key, "content") and entry.value_ptr.* == .string) {'''
    new_role_rewrite = '''        if (std.mem.eql(u8, key, "content") and entry.value_ptr.* == .string) {'''
    if old_role_rewrite not in text:
        raise SystemExit("providers.zig: stale developer-role rewrite not found")
    text = text.replace(old_role_rewrite, new_role_rewrite, 1)

    old_sig = 'fn buildNativeResponsesRequest(w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {'
    new_sig = 'fn buildNativeResponsesRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {'
    if old_sig not in text:
        raise SystemExit("providers.zig: buildNativeResponsesRequest signature not found")
    text = text.replace(old_sig, new_sig, 1)

    start_marker = '''    try w.writeAll(",\\\"stream\\\":true");\n    const selected_tool_name = if (parsed.object.get("tool_choice")) |choice| namedToolChoice(choice) else null;'''
    start_replacement = '''    try w.writeAll(",\\\"stream\\\":true");\n    const selected_tool_name = if (parsed.object.get("tool_choice")) |choice| namedToolChoice(choice) else null;\n    const instructions = try collectNativeResponsesInstructions(allocator, parsed);\n    defer if (instructions) |value| allocator.free(value);'''
    if start_marker not in text:
        raise SystemExit("providers.zig: native Responses start marker not found")
    text = text.replace(start_marker, start_replacement, 1)

    old_skip = '''            std.mem.eql(u8, key, "max_tokens") or\n            std.mem.eql(u8, key, "tools"))'''
    new_skip = '''            std.mem.eql(u8, key, "max_tokens") or\n            std.mem.eql(u8, key, "tools") or\n            (instructions != null and std.mem.eql(u8, key, "instructions")))'''
    if old_skip not in text:
        raise SystemExit("providers.zig: native Responses key skip pattern not found")
    text = text.replace(old_skip, new_skip, 1)

    before_tools = '''    try writeMergedResponsesToolsForZed(w, parsed.object.get("tools"), parsed.object.get("input"), selected_tool_name);'''
    emit_instructions = '''    if (instructions) |value| {\n        try w.writeAll(",\\\"instructions\\\":");\n        try std.json.Stringify.encodeJsonString(value, .{}, w);\n    }\n\n    try writeMergedResponsesToolsForZed(w, parsed.object.get("tools"), parsed.object.get("input"), selected_tool_name);'''
    if before_tools not in text:
        raise SystemExit("providers.zig: tools emission marker not found")
    text = text.replace(before_tools, emit_instructions, 1)

    # Update the older regression test that expected developer -> system inside input.
    old_assertions = '''    const input = request.get("input").?.array;\n    try std.testing.expectEqual(@as(usize, 2), input.items.len);\n    try std.testing.expectEqualStrings("system", input.items[0].object.get("role").?.string);\n    try std.testing.expectEqualStrings("user", input.items[1].object.get("role").?.string);'''
    new_assertions = '''    try std.testing.expectEqualStrings("follow project rules", request.get("instructions").?.string);\n    const input = request.get("input").?.array;\n    try std.testing.expectEqual(@as(usize, 1), input.items.len);\n    try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);'''
    if old_assertions not in text:
        raise SystemExit("providers.zig: older developer-role test assertions not found")
    text = text.replace(old_assertions, new_assertions, 1)

    # Surface HTTP-200 Zed completion failures instead of degrading them to InvalidUpstreamResponse.
    conversion_marker = '''        if (parsed.value != .object) continue;\n        const event = parsed.value.object.get("event") orelse parsed.value;'''
    conversion_replacement = '''        if (parsed.value != .object) continue;\n\n        var control = completion_status.parseLine(allocator, line);\n        defer control.deinit(allocator);\n        if (control.kind == .failed) {\n            std.debug.print("[zed] completion failed: code={s} message={s}\\n", .{ control.code orelse "unknown", control.message orelse "unknown" });\n            return error.UpstreamError;\n        }\n        if (control.kind == .queued or control.kind == .started or control.kind == .stream_ended or control.kind == .unknown_status) continue;\n\n        const event = parsed.value.object.get("event") orelse parsed.value;'''
    if conversion_marker not in text:
        raise SystemExit("providers.zig: convertToResponses marker not found")
    text = text.replace(conversion_marker, conversion_replacement, 1)

    write(path, text)


def red_stream() -> None:
    append_once("src/stream.zig", STREAM_TEST_MARKER, STREAM_STUBS_AND_TESTS)


def green_stream() -> None:
    path = "src/stream.zig"
    text = read(path)
    if 'const completion_status = @import("completion_status.zig");' not in text:
        text = text.replace('const providers = @import("providers.zig");\n', 'const providers = @import("providers.zig");\nconst completion_status = @import("completion_status.zig");\n', 1)

    stub_helpers = STREAM_STUBS_AND_TESTS.split('test "Responses stream classifier rejects Zed control messages"', 1)[0].rstrip()
    impl_helpers = STREAM_IMPL_HELPERS.strip()
    if stub_helpers not in text:
        raise SystemExit("stream.zig: RED helper stubs not found")
    text = text.replace(stub_helpers, impl_helpers, 1)

    ended_var = '''    var ended_by_marker = false;\n\n    const model_owned = providers.extractModelFromBody(allocator, body) catch null;'''
    ended_var_new = '''    var ended_by_marker = false;\n    var responses_terminal_seen = false;\n\n    const model_owned = providers.extractModelFromBody(allocator, body) catch null;'''
    if ended_var not in text:
        raise SystemExit("stream.zig: ended_by_marker variable marker not found")
    text = text.replace(ended_var, ended_var_new, 1)

    old_marker_block = '''                // The marker is protocol metadata, not a model event. Detect it\n                // structurally before sending SSE headers or counting data.\n                if (line[0] == '{' and\n                    std.mem.indexOf(u8, line, "\\\"status\\\"") != null and\n                    std.mem.indexOf(u8, line, "\\\"stream_ended\\\"") != null and\n                    isStreamEndedMarker(line, allocator))\n                {\n                    line_len = 0;\n                    ended_by_marker = true;\n                    break;\n                }'''
    new_marker_block = '''                // Zed's cloud protocol multiplexes queue/start/failure/end status\n                // messages with provider events. Never commit downstream SSE for\n                // control-plane JSON. In particular, HTTP 200 + status.failed is\n                // an upstream failure, not a successful empty model response.\n                var control = completion_status.parseLine(allocator, line);\n                defer control.deinit(allocator);\n                switch (control.kind) {\n                    .queued, .started, .unknown_status => {\n                        line_len = 0;\n                        continue;\n                    },\n                    .failed => {\n                        const mapped_status = completion_status.suggestedHttpStatus(control);\n                        const is_plan_failure = if (control.message) |message| std.mem.indexOf(u8, message, "plan") != null else false;\n                        const mapped_kind: accounts.FailureKind = if (mapped_status == 401)\n                            .auth\n                        else if (mapped_status == 403)\n                            (if (is_plan_failure) .transient else .auth)\n                        else if (mapped_status == 429)\n                            .rate_limit\n                        else\n                            .transient;\n                        std.debug.print("[stream] upstream completion failed: code={s} message={s}\\n", .{ control.code orelse "unknown", control.message orelse "unknown" });\n                        return .{ .ok = false, .kind = mapped_kind, .status = mapped_status };\n                    },\n                    .stream_ended => {\n                        line_len = 0;\n                        ended_by_marker = true;\n                        break;\n                    },\n                    .event, .not_status => {},\n                }'''
    if old_marker_block not in text:
        raise SystemExit("stream.zig: old stream-ended marker block not found")
    text = text.replace(old_marker_block, new_marker_block, 1)

    headers_marker = '''                    if (!headers_sent) {\n                        headers_sent = true;'''
    headers_insert = '''                    const responses_event_class: ResponsesEventClass = if (is_responses)\n                        classifyResponsesEventLine(line, allocator)\n                    else\n                        .event;\n                    if (is_responses and responses_event_class == .none) {\n                        line_len = 0;\n                        continue;\n                    }\n\n                    if (!headers_sent) {\n                        headers_sent = true;'''
    if headers_marker not in text:
        raise SystemExit("stream.zig: SSE header marker not found")
    text = text.replace(headers_marker, headers_insert, 1)

    response_branch = '''                    got_any_data = true;\n                    if (is_responses) {\n                        passThroughResponsesSSE(client_stream, line, allocator) catch'''
    response_branch_new = '''                    got_any_data = true;\n                    if (is_responses) {\n                        if (responses_event_class == .terminal) responses_terminal_seen = true;\n                        passThroughResponsesSSE(client_stream, line, allocator) catch'''
    if response_branch not in text:
        raise SystemExit("stream.zig: Responses forwarding branch not found")
    text = text.replace(response_branch, response_branch_new, 1)

    ended_block = '''    if (ended_by_marker) {\n        _ = child.kill() catch {};'''
    ended_block_new = '''    if (ended_by_marker) {\n        // `stream_ended` is Zed transport metadata, while OpenAI-compatible\n        // clients need a terminal Responses frame. If real provider events were\n        // relayed but no response.completed/failed/incomplete arrived, bridge\n        // the cloud-level end marker to the conventional [DONE] sentinel.\n        if (shouldSendResponsesDone(is_responses, got_any_data, responses_terminal_seen)) {\n            socket.send(client_stream, "data: [DONE]\\n\\n") catch\n                return .{ .ok = false, .committed = headers_sent, .kind = .transient, .status = http_status };\n        }\n        _ = child.kill() catch {};'''
    if ended_block not in text:
        raise SystemExit("stream.zig: ended_by_marker completion block not found")
    text = text.replace(ended_block, ended_block_new, 1)

    write(path, text)


def patch_proxy_version() -> None:
    replace_once("src/proxy.zig", 'pub const ZED_VERSION = "1.8.2";', 'pub const ZED_VERSION = "1.16.2";')


def patch_build() -> None:
    path = "build.zig"
    text = read(path)
    if 'src/completion_status.zig' in text:
        return
    marker = '''    const settings_test_mod = b.createModule(.{\n        .root_source_file = b.path("src/settings.zig"),'''
    insertion = '''    const completion_status_test_mod = b.createModule(.{\n        .root_source_file = b.path("src/completion_status.zig"),\n        .target = target,\n        .optimize = optimize,\n        .link_libc = true,\n    });\n    const completion_status_tests = b.addTest(.{ .root_module = completion_status_test_mod });\n    const run_completion_status_tests = b.addRunArtifact(completion_status_tests);\n\n    const settings_test_mod = b.createModule(.{\n        .root_source_file = b.path("src/settings.zig"),'''
    if marker not in text:
        raise SystemExit("build.zig: settings test marker not found")
    text = text.replace(marker, insertion, 1)
    dep = '    test_step.dependOn(&run_stream_tests.step);\n'
    if dep not in text:
        raise SystemExit("build.zig: stream test dependency marker not found")
    text = text.replace(dep, dep + '    test_step.dependOn(&run_completion_status_tests.step);\n', 1)
    write(path, text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=[
        "red-status", "green-status", "red-providers", "green-providers",
        "red-stream", "green-stream", "proxy-version", "build",
    ])
    args = parser.parse_args()
    {
        "red-status": red_status,
        "green-status": green_status,
        "red-providers": red_providers,
        "green-providers": green_providers,
        "red-stream": red_stream,
        "green-stream": green_stream,
        "proxy-version": patch_proxy_version,
        "build": patch_build,
    }[args.mode]()


if __name__ == "__main__":
    main()
