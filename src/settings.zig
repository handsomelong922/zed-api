const std = @import("std");

const DEFAULT_PATH = "settings.json";

pub const Source = enum { none, file, env };

pub const Status = struct {
    enabled: bool,
    source: Source,
};

pub const ApiKeySettings = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    persisted_key: ?[]u8 = null,
    env_key: ?[]u8 = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ApiKeySettings {
        var self = ApiKeySettings{
            .allocator = allocator,
            .path = DEFAULT_PATH,
        };
        self.loadEnv();
        self.loadFile();
        return self;
    }

    fn initForTest(allocator: std.mem.Allocator, path: []const u8, env_value: ?[]const u8) !ApiKeySettings {
        var self = ApiKeySettings{
            .allocator = allocator,
            .path = path,
        };
        if (env_value) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) self.env_key = try allocator.dupe(u8, trimmed);
        }
        self.loadFile();
        return self;
    }

    pub fn deinit(self: *ApiKeySettings) void {
        if (self.persisted_key) |key| self.allocator.free(key);
        if (self.env_key) |key| self.allocator.free(key);
        self.persisted_key = null;
        self.env_key = null;
    }

    fn loadEnv(self: *ApiKeySettings) void {
        const raw = std.process.getEnvVarOwned(self.allocator, "ZED_API_KEY") catch return;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            self.allocator.free(raw);
            return;
        }
        if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) {
            self.env_key = raw;
            return;
        }
        self.env_key = self.allocator.dupe(u8, trimmed) catch {
            self.allocator.free(raw);
            return;
        };
        self.allocator.free(raw);
    }

    fn loadFile(self: *ApiKeySettings) void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, 64 * 1024) catch return;
        defer self.allocator.free(bytes);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const value = parsed.value.object.get("api_key") orelse return;
        if (value != .string) return;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (trimmed.len == 0) return;
        self.persisted_key = self.allocator.dupe(u8, trimmed) catch null;
    }

    fn effectiveKeyLocked(self: *const ApiKeySettings) ?[]const u8 {
        if (self.persisted_key) |key| return key;
        if (self.env_key) |key| return key;
        return null;
    }

    fn sourceLocked(self: *const ApiKeySettings) Source {
        if (self.persisted_key != null) return .file;
        if (self.env_key != null) return .env;
        return .none;
    }

    pub fn status(self: *ApiKeySettings) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        const source = self.sourceLocked();
        return .{ .enabled = source != .none, .source = source };
    }

    /// Authentication is disabled when there is no effective key. Otherwise
    /// the caller must provide an exact matching credential.
    pub fn authorize(self: *ApiKeySettings, candidate: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const expected = self.effectiveKeyLocked() orelse return true;
        const supplied = candidate orelse return false;
        return std.mem.eql(u8, supplied, expected);
    }

    pub fn saveKey(self: *ApiKeySettings, raw_key: []const u8) !void {
        const key = std.mem.trim(u8, raw_key, " \t\r\n");
        if (key.len == 0) return error.EmptyApiKey;

        self.mutex.lock();
        defer self.mutex.unlock();

        var json: std.io.Writer.Allocating = .init(self.allocator);
        defer json.deinit();
        try json.writer.writeAll("{\"api_key\":");
        try std.json.Stringify.encodeJsonString(key, .{}, &json.writer);
        try json.writer.writeAll("}\n");

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);
        {
            const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(json.written());
            try file.sync();
        }
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

        std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try std.fs.cwd().rename(tmp_path, self.path);

        const owned = try self.allocator.dupe(u8, key);
        if (self.persisted_key) |old| self.allocator.free(old);
        self.persisted_key = owned;
    }

    pub fn clearKey(self: *ApiKeySettings) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (self.persisted_key) |old| self.allocator.free(old);
        self.persisted_key = null;
    }
};

test "persisted key overrides environment fallback and survives reload" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "settings-test-{d}.json", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};
    var tmp_buf: [132]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var first = try ApiKeySettings.initForTest(allocator, path, "env-secret");
    defer first.deinit();
    try std.testing.expectEqual(Source.env, first.status().source);
    try std.testing.expect(first.authorize("env-secret"));

    try first.saveKey(" web-secret ");
    try std.testing.expectEqual(Source.file, first.status().source);
    try std.testing.expect(first.authorize("web-secret"));
    try std.testing.expect(!first.authorize("env-secret"));

    var second = try ApiKeySettings.initForTest(allocator, path, "env-secret");
    defer second.deinit();
    try std.testing.expectEqual(Source.file, second.status().source);
    try std.testing.expect(second.authorize("web-secret"));
}

test "clearing persisted key falls back to environment" {
    const allocator = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "settings-clear-test-{d}.json", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};
    var tmp_buf: [132]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var settings = try ApiKeySettings.initForTest(allocator, path, "env-secret");
    defer settings.deinit();
    try settings.saveKey("web-secret");
    try settings.clearKey();
    const status = settings.status();
    try std.testing.expect(status.enabled);
    try std.testing.expectEqual(Source.env, status.source);
    try std.testing.expect(settings.authorize("env-secret"));
}
