# Web API Key and Streaming Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent API Key setting in the Web UI and make Docker deployments reliably support streaming OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages.

**Architecture:** Introduce a small `src/settings.zig` module that owns `/data/settings.json`, loads a persisted API key first and falls back to `ZED_API_KEY` only when no persisted key exists. Expose unprotected `/zed/settings/api-key` management endpoints that never return the secret itself, wire a new Web UI security page to those endpoints, and keep model API authentication in `server.zig`. Repair streaming by ensuring runtime `curl` exists, hardening SSE response headers/socket writes, and regression-testing protocol framing in-process plus Docker runtime prerequisites.

**Tech Stack:** Zig 0.15.2, TypeScript/Vite Web UI, Alpine Docker, curl SSE transport, GitHub Actions.

---

## File map

- Create `src/settings.zig`: load/save/clear persistent API-key configuration and environment fallback.
- Modify `src/server.zig`: initialize settings, authenticate protected routes, add settings management routes.
- Modify `src/socket.zig`: guarantee full writes and expose a streaming response header helper if needed.
- Modify `src/stream.zig`: emit proxy-safe SSE headers and preserve protocol-specific streaming framing.
- Modify `Dockerfile`: install runtime `curl` alongside `openssl`.
- Modify `webui/src/api.ts`: settings API client types/functions.
- Create `webui/src/pages/security.ts`: API Key settings UI.
- Modify `webui/src/main.ts`: add Security navigation/page and use an unprotected health endpoint for UI status.
- Modify `webui/src/style.css`: styles for the API-key settings form.
- Modify `.github/workflows/ci.yml`: regression tests for persisted key behavior, runtime curl, and streaming protocol framing.
- Modify `README.md`: document Web UI configuration precedence and streaming support.

### Task 1: Persistent API-key settings module

**Files:**
- Create: `src/settings.zig`
- Modify: `src/server.zig`
- Test: Zig unit tests in `src/settings.zig`

- [ ] **Step 1: Write failing tests for precedence and persistence**

Add tests that write an isolated temporary `settings.json`, assert persisted `api_key` wins over an environment fallback, assert clearing removes the persisted key, and assert status serialization never returns the secret.

- [ ] **Step 2: Run the tests and verify RED**

Run: `zig build test`
Expected: FAIL because `settings.zig` and its API do not exist yet.

- [ ] **Step 3: Implement `ApiKeySettings`**

Use this public shape:

```zig
pub const ApiKeySettings = struct {
    allocator: std.mem.Allocator,
    persisted_key: ?[]u8 = null,
    env_key: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) ApiKeySettings;
    pub fn deinit(self: *ApiKeySettings) void;
    pub fn load(self: *ApiKeySettings) void;
    pub fn effectiveKey(self: *const ApiKeySettings) ?[]const u8;
    pub fn source(self: *const ApiKeySettings) enum { none, file, env };
    pub fn saveKey(self: *ApiKeySettings, key: []const u8) !void;
    pub fn clearKey(self: *ApiKeySettings) !void;
};
```

Persist to cwd-relative `/data/settings.json` as:

```json
{"api_key":"sk-example"}
```

Treat an absent/empty persisted value as no file key. Load `ZED_API_KEY` only as fallback. Write the file atomically through a temporary file plus rename.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/settings.zig src/server.zig
git commit -m "feat: persist API key settings"
```

### Task 2: Web management API for the key

**Files:**
- Modify: `src/server.zig`
- Test: `.github/workflows/ci.yml`

- [ ] **Step 1: Add failing Docker smoke assertions**

Start a container with a persistent `/data` volume and no environment key. Assert:

```text
GET  /zed/settings/api-key -> 200 {"enabled":false,"source":"none"}
POST /zed/settings/api-key {"api_key":"test-secret"} -> 200
POST /v1/messages/count_tokens without key -> 401
POST /v1/messages/count_tokens with Bearer test-secret -> 200
GET  /zed/settings/api-key -> 200 {"enabled":true,"source":"file"}
```

Restart the container on the same volume and assert the key is still active. Then:

```text
DELETE /zed/settings/api-key -> 200
POST /v1/messages/count_tokens without key -> 200
```

- [ ] **Step 2: Run PR CI and verify RED**

Expected: settings endpoints return 404.

- [ ] **Step 3: Implement routes**

Add unprotected management routes:

```text
GET    /zed/settings/api-key
POST   /zed/settings/api-key
DELETE /zed/settings/api-key
```

GET returns only:

```json
{"enabled":true,"source":"file"}
```

POST accepts JSON `{ "api_key": "..." }`, trims surrounding whitespace, rejects empty keys with 400, saves immediately, and updates the in-memory effective key without restart. DELETE removes only the persisted key; if `ZED_API_KEY` exists the effective source falls back to `env`, otherwise authentication becomes disabled.

- [ ] **Step 4: Run CI and verify GREEN**

Expected: persistence/auth smoke passes.

- [ ] **Step 5: Commit**

```bash
git add src/server.zig .github/workflows/ci.yml
git commit -m "feat: manage API key from web backend"
```

### Task 3: Web UI Security page

**Files:**
- Modify: `webui/src/api.ts`
- Create: `webui/src/pages/security.ts`
- Modify: `webui/src/main.ts`
- Modify: `webui/src/style.css`
- Test: Vite build and Docker HTML smoke

- [ ] **Step 1: Add failing HTML smoke checks**

After loading `/`, assert the embedded UI contains `API Key 设置`, `保存 API Key`, and `清除 API Key`.

- [ ] **Step 2: Run CI and verify RED**

Expected: grep fails because the page does not exist.

- [ ] **Step 3: Add API client functions**

In `webui/src/api.ts` add:

```ts
export interface ApiKeySettingsStatus {
  enabled: boolean
  source: 'none' | 'file' | 'env'
}

export async function fetchApiKeySettings(): Promise<ApiKeySettingsStatus>
export async function saveApiKey(apiKey: string): Promise<ApiKeySettingsStatus>
export async function clearApiKey(): Promise<ApiKeySettingsStatus>
```

Never expose or cache the current secret.

- [ ] **Step 4: Build `security.ts`**

Render a compact settings card with a password input, show/hide toggle, status chip, Save button, and Clear button. After save, clear the input value immediately. Status text distinguishes `网页配置` vs `环境变量后备` vs `未启用`.

- [ ] **Step 5: Wire navigation and unprotected service status**

Add `security` to `PageId`, navigation, title map, page stage, and render call. Change `refreshServiceState()` to probe an unprotected route such as `/zed/settings/api-key` rather than `/v1/models`, so enabling API auth does not make the Web UI claim the service is offline.

- [ ] **Step 6: Build Web UI**

Run: `cd webui && npm ci && npm run build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add webui/src/api.ts webui/src/pages/security.ts webui/src/main.ts webui/src/style.css .github/workflows/ci.yml
git commit -m "feat: add web API key settings"
```

### Task 4: Repair Docker streaming runtime

**Files:**
- Modify: `Dockerfile`
- Modify: `src/socket.zig`
- Modify: `src/stream.zig`
- Test: Zig tests and Docker smoke

- [ ] **Step 1: Add failing runtime prerequisite test**

In Docker smoke, assert:

```bash
docker run --rm --entrypoint sh zed-api:smoke -c 'command -v curl && curl --version'
```

Expected before fix: FAIL because runtime image installs only `openssl`.

- [ ] **Step 2: Install runtime curl**

Change Alpine runtime dependencies to:

```dockerfile
RUN apk add --no-cache openssl curl
```

- [ ] **Step 3: Harden socket writes**

Change `socket.send` so it loops until all bytes are written or an error occurs; do not assume a single TCP write consumes the full buffer.

- [ ] **Step 4: Harden SSE headers**

For all stream modes emit:

```text
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
X-Accel-Buffering: no
Connection: close
Access-Control-Allow-Origin: *
Access-Control-Allow-Headers: *
```

Keep one-request-per-connection semantics.

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile src/socket.zig src/stream.zig .github/workflows/ci.yml
git commit -m "fix: restore Docker SSE streaming"
```

### Task 5: Verify Chat, Responses, and Anthropic stream framing

**Files:**
- Modify: `src/stream.zig`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add deterministic formatter tests**

Factor or expose pure helpers that transform representative Zed JSON-line events into protocol output and assert:

OpenAI Chat:

```text
data: {"object":"chat.completion.chunk",...}

data: [DONE]

```

OpenAI Responses:

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta",...}

```

and completion:

```text
event: response.completed
data: {"type":"response.completed",...}

```

Anthropic:

```text
event: message_start
...
event: content_block_delta
...
event: message_stop
```

- [ ] **Step 2: Verify `stream:true` routing**

Add/extend server tests so `/v1/chat/completions`, `/v1/responses`, and `/v1/messages` with `stream:true` all select `handleStreamProxy` with the correct `is_anthropic` / `is_responses` mode; `stream:false` continues to use non-stream proxy behavior.

- [ ] **Step 3: Verify Responses pass-through semantics**

Ensure `passThroughResponsesSSE` unwraps Zed's `{ "event": ... }` wrapper and emits a standard SSE `event:` line matching the embedded Responses event `type`, followed by JSON `data:`. Do not translate Responses events into Chat chunks.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/stream.zig src/server.zig .github/workflows/ci.yml
git commit -m "test: cover streaming protocol compatibility"
```

### Task 6: Documentation, full verification, and release

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document configuration precedence**

State: Web UI `/data/settings.json` key takes precedence; `ZED_API_KEY` remains a fallback only. The UI never redisplays the saved secret.

- [ ] **Step 2: Document streaming endpoints**

Document support for:

```text
POST /v1/chat/completions  stream:true
POST /v1/responses         stream:true
POST /v1/messages          stream:true
```

- [ ] **Step 3: Run full PR CI**

Require success for Zig tests, Web UI build, linux/amd64, linux/arm64, Docker amd64/arm64, one-port smoke, persisted API-key smoke, runtime curl, and streaming formatter/routing tests.

- [ ] **Step 4: Review final diff**

Confirm no port/address/login changes and no secret is logged or returned.

- [ ] **Step 5: Merge PR only after green CI**

Use squash merge with final head SHA guard.

- [ ] **Step 6: Verify main CI and Docker publication**

Require main CI `success` and Docker workflow `Build and push multi-arch image` `success` for the merge commit before telling the user to pull `ghcr.io/handsomelong922/zed-api:latest`.
