const std = @import("std");
const auth = @import("auth.zig");
const accounts = @import("accounts.zig");

const MAX_REQUEST = 32 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const port_str = args.next() orelse "8002";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8002;

    var keypair = try auth.RsaKeyPair.generate(allocator);
    defer keypair.deinit();
    const pub_key = try keypair.exportPublicKeyB64(allocator);
    defer allocator.free(pub_key);
    const login_url = try std.fmt.allocPrint(
        allocator,
        "https://zed.dev/native_app_signin?native_app_port={d}&native_app_public_key={s}",
        .{ port, pub_key },
    );
    defer allocator.free(login_url);

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try addr.listen(.{ .reuse_address = false });
    defer server.deinit();

    std.debug.print("[setup] browser setup page listening on 0.0.0.0:{d}\n", .{port});

    while (true) {
        const conn = server.accept() catch continue;
        const completed = handleConnection(allocator, conn.stream, &keypair, login_url) catch |err| {
            std.debug.print("[setup] request failed: {}\n", .{err});
            conn.stream.close();
            continue;
        };
        conn.stream.close();
        if (completed) {
            std.debug.print("[setup] account saved; setup server exiting\n", .{});
            return;
        }
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    keypair: *auth.RsaKeyPair,
    login_url: []const u8,
) !bool {
    var buf: [MAX_REQUEST]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
            const content_length = parseContentLength(buf[0..header_end]);
            if (total >= header_end + 4 + content_length) break;
        }
    }

    const data = buf[0..total];
    const line_end = std.mem.indexOf(u8, data, "\r\n") orelse return error.BadRequest;
    const request_line = data[0..line_end];
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const path = parts.next() orelse return error.BadRequest;

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) {
        const page = try renderPage(allocator, login_url, null);
        defer allocator.free(page);
        try sendHtml(stream, 200, page);
        return false;
    }

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/complete")) {
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.BadRequest;
        const body = data[header_end + 4 ..];
        const encoded = formValue(body, "callback_url") orelse {
            const page = try renderPage(allocator, login_url, "没有收到回调地址，请重新复制浏览器地址栏中的完整 URL。");
            defer allocator.free(page);
            try sendHtml(stream, 400, page);
            return false;
        };
        const callback_url = try urlDecode(allocator, encoded);
        defer allocator.free(callback_url);

        const creds = credentialsFromCallbackUrl(allocator, keypair, callback_url) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "回调解析或解密失败：{s}", .{@errorName(err)});
            defer allocator.free(msg);
            const page = try renderPage(allocator, login_url, msg);
            defer allocator.free(page);
            try sendHtml(stream, 400, page);
            return false;
        };
        defer allocator.free(creds.user_id);
        defer allocator.free(creds.access_token);

        try accounts.addAccount(allocator, creds.user_id, creds.user_id, creds.access_token);
        const flag = try std.fs.cwd().createFile("setup-complete.flag", .{});
        flag.close();

        try sendHtml(stream, 200,
            "<!doctype html><meta charset=\"utf-8\"><title>登录成功</title>"
            ++ "<style>body{font-family:system-ui;max-width:760px;margin:80px auto;padding:24px;line-height:1.7}"
            ++ ".ok{padding:20px;border:1px solid #b7e4c7;border-radius:12px;background:#f0fff4}</style>"
            ++ "<div class=\"ok\"><h2>✅ Zed 账号已保存</h2>"
            ++ "<p>主服务正在自动重新加载账号。请返回 8001 的 Zed API 页面，等待几秒后刷新。</p></div>");
        return true;
    }

    try sendHtml(stream, 404, "<!doctype html><meta charset=\"utf-8\"><h1>404</h1>");
    return false;
}

fn credentialsFromCallbackUrl(
    allocator: std.mem.Allocator,
    keypair: *auth.RsaKeyPair,
    callback_url: []const u8,
) !auth.Credentials {
    const query_start = std.mem.indexOfScalar(u8, callback_url, '?') orelse return error.BadCallback;
    const query = callback_url[query_start + 1 ..];

    const uid_encoded = queryValue(query, "user_id") orelse return error.NoUserId;
    const token_encoded = queryValue(query, "access_token") orelse return error.NoToken;
    const uid = try urlDecode(allocator, uid_encoded);
    errdefer allocator.free(uid);
    const encrypted_token = try urlDecode(allocator, token_encoded);
    defer allocator.free(encrypted_token);

    var padded_buf: [4096]u8 = undefined;
    const pad_needed = (4 - (encrypted_token.len % 4)) % 4;
    if (encrypted_token.len + pad_needed > padded_buf.len) return error.TokenTooLong;
    @memcpy(padded_buf[0..encrypted_token.len], encrypted_token);
    for (0..pad_needed) |i| padded_buf[encrypted_token.len + i] = '=';
    const padded = padded_buf[0 .. encrypted_token.len + pad_needed];

    const decoder = std.base64.url_safe.Decoder;
    const decoded_len = decoder.calcSizeForSlice(padded) catch return error.BadBase64;
    const ciphertext = try allocator.alloc(u8, decoded_len);
    defer allocator.free(ciphertext);
    decoder.decode(ciphertext, padded) catch return error.BadBase64;

    const plaintext = try keypair.decrypt(allocator, ciphertext);
    return .{ .user_id = uid, .access_token = plaintext };
}

fn renderPage(allocator: std.mem.Allocator, login_url: []const u8, error_message: ?[]const u8) ![]u8 {
    const escaped_url = try htmlEscape(allocator, login_url);
    defer allocator.free(escaped_url);
    const escaped_error = if (error_message) |msg| try htmlEscape(allocator, msg) else null;
    defer if (escaped_error) |msg| allocator.free(msg);

    return std.fmt.allocPrint(allocator,
        "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        ++ "<title>Zed API 远程账号初始化</title><style>body{{font-family:system-ui;background:#f6f7f9;color:#202124;margin:0}}"
        ++ ".card{{max-width:820px;margin:50px auto;background:white;padding:32px;border-radius:16px;box-shadow:0 6px 30px #0001}}"
        ++ "a.btn,button{{display:inline-block;background:#111827;color:white;padding:11px 18px;border-radius:9px;text-decoration:none;border:0;font-size:15px;cursor:pointer}}"
        ++ "textarea{{width:100%;box-sizing:border-box;min-height:120px;padding:12px;border:1px solid #ccd1d9;border-radius:9px;font-family:ui-monospace,monospace}}"
        ++ ".step{{margin:24px 0;padding:18px;border:1px solid #e5e7eb;border-radius:12px}}.err{{color:#b42318;background:#fff1f0;padding:12px;border-radius:8px}}"
        ++ "code{{background:#f2f4f7;padding:2px 5px;border-radius:4px}}</style><div class=\"card\"><h1>Zed API 远程账号初始化</h1>"
        ++ "<p>适用于 1Panel / Docker / 云服务器，无需 SSH 或容器终端。</p>"
        ++ "{s}<div class=\"step\"><b>1. 打开 Zed 授权页面</b><p>完成 GitHub / Zed 登录后，浏览器会跳到 <code>127.0.0.1:8002</code>。"
        ++ "因为这是远程服务器场景，该页面打不开是正常的。</p><a class=\"btn\" target=\"_blank\" rel=\"noreferrer\" href=\"{s}\">打开 Zed 授权</a></div>"
        ++ "<div class=\"step\"><b>2. 复制失败页面地址栏中的完整 URL</b><p>必须包含 <code>user_id</code> 和 <code>access_token</code>。</p>"
        ++ "<form method=\"post\" action=\"/complete\"><textarea name=\"callback_url\" required placeholder=\"http://127.0.0.1:8002/?user_id=...&access_token=...\"></textarea>"
        ++ "<p><button type=\"submit\">完成账号导入</button></p></form></div></div></html>",
        .{ if (escaped_error) |msg| try std.fmt.allocPrint(allocator, "<div class=\"err\">{s}</div>", .{msg}) else "", escaped_url },
    );
}

fn parseContentLength(headers: []const u8) usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch 0;
        }
    }
    return 0;
}

fn formValue(body: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..eq], key)) return field[eq + 1 ..];
    }
    return null;
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..eq], key)) return field[eq + 1 ..];
    }
    return null;
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse return error.BadEncoding;
            const lo = hexVal(input[i + 2]) orelse return error.BadEncoding;
            try w.writeByte((hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try w.writeByte(' ');
            i += 1;
        } else {
            try w.writeByte(input[i]);
            i += 1;
        }
    }
    return try allocator.dupe(u8, out.items);
}

fn htmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    for (input) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
    return try allocator.dupe(u8, out.items);
}

fn sendHtml(stream: std.net.Stream, status: u16, body: []const u8) !void {
    var header_buf: [256]u8 = undefined;
    const reason = if (status == 200) "OK" else if (status == 400) "Bad Request" else "Not Found";
    const header = try std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, reason, body.len },
    );
    try stream.writeAll(header);
    try stream.writeAll(body);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

test "queryValue extracts OAuth fields" {
    const query = "user_id=123&access_token=abc%2Bdef";
    try std.testing.expectEqualStrings("123", queryValue(query, "user_id").?);
    try std.testing.expectEqualStrings("abc%2Bdef", queryValue(query, "access_token").?);
}

test "urlDecode handles percent and form encoding" {
    const decoded = try urlDecode(std.testing.allocator, "http%3A%2F%2F127.0.0.1%3A8002%2F%3Fa%3Db+c");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("http://127.0.0.1:8002/?a=b c", decoded);
}
