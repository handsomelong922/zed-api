# API Key Mutation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven development and verification-before-completion. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent an unauthenticated visitor from replacing or clearing an already-enabled API key while keeping first-time Web setup simple.

**Architecture:** Keep `GET /zed/settings/api-key` public and secret-free. `POST` and `DELETE` remain usable without credentials only while no effective key exists; once a persisted or environment key is active, they require that current key through `Authorization: Bearer <key>` or `x-api-key`. The Web UI asks for the current key only when the status says protection is enabled, sends it for the mutation request, and never stores or redisplays it.

**Tech Stack:** Zig 0.15.2 HTTP server, TypeScript/Vite Web UI, Docker smoke tests, GitHub Actions.

---

### Task 1: RED regression coverage

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] Add Docker smoke assertions proving first-time unauthenticated save works, then unauthenticated/wrong-key rotate and clear requests must return 401, correct-current-key rotation succeeds immediately, the old key stops working, the new key persists across restart, and authenticated clear succeeds.
- [ ] Run PR CI and confirm the new smoke test fails on the pre-hardening server specifically because settings mutation is still unauthenticated.

### Task 2: Backend authorization

**Files:**
- Modify: `src/server.zig`

- [ ] Treat `POST` and `DELETE /zed/settings/api-key` as protected whenever an effective key exists by reusing the same current-key authorization logic as `/v1/*`.
- [ ] Keep `GET /zed/settings/api-key` public and keep first-time save working because `ApiKeySettings.authorize()` intentionally permits requests when no effective key exists.

### Task 3: Web UI current-key flow

**Files:**
- Modify: `webui/src/api.ts`
- Modify: `webui/src/pages/security.ts`

- [ ] Extend `saveApiKey(newKey, currentKey?)` and `clearApiKey(currentKey?)` to send `Authorization: Bearer <currentKey>` only when supplied.
- [ ] Track the latest public settings status in the Security page. When protection is enabled, show a separate password field labeled `当前 API Key（验证身份）`; require it before rotate/clear. When disabled, hide that field and allow first-time save directly.
- [ ] Clear both password inputs after each successful mutation and never use local/session storage.
- [ ] Add embedded-HTML smoke checks for the current-key UI text.

### Task 4: GREEN verification and release

- [ ] Run full PR CI: Zig tests, Web UI build, linux/amd64, linux/arm64, Docker amd64/arm64, one-port/OAuth smoke, runtime curl, API-key mutation hardening.
- [ ] Review the PR diff for secret leakage, port/address changes, and OAuth regressions.
- [ ] Squash-merge only with green checks and an expected-head SHA guard.
- [ ] Verify post-merge `main` CI and multi-arch GHCR publication are both successful before declaring `latest` ready.
