# ZED_API_KEY Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one optional global API key configured through `ZED_API_KEY` for model-facing API routes.

**Architecture:** Load the environment variable once when the server starts. Before any `/v1/*` or `/api/event_logging/batch` request is routed or streamed, validate either `Authorization: Bearer <key>` or `x-api-key: <key>` from the already-parsed HTTP headers. Keep Web UI and Zed account-management routes unchanged.

**Tech Stack:** Zig 0.15.2, Docker/Alpine, GitHub Actions shell smoke tests.

---

### Task 1: Add failing Docker authentication smoke coverage

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add a smoke test container started with `-e ZED_API_KEY=test-secret`.**
- [ ] **Step 2: Assert `/v1/models` returns 401 with no credential and with a wrong credential.**
- [ ] **Step 3: Assert `/v1/models` returns 200 with `Authorization: Bearer test-secret`.**
- [ ] **Step 4: Assert `/v1/models` returns 200 with `x-api-key: test-secret`.**
- [ ] **Step 5: Run PR CI and verify this job fails before production code is changed.**

### Task 2: Implement minimal server-side API-key validation

**Files:**
- Modify: `src/server.zig`

- [ ] **Step 1: Load `ZED_API_KEY` once at server startup; treat unset/empty as authentication disabled.**
- [ ] **Step 2: Add helpers that identify protected paths and validate Bearer or `x-api-key` headers without logging secrets.**
- [ ] **Step 3: Reject protected requests with HTTP 401 before stream/non-stream routing when validation fails.**
- [ ] **Step 4: Run CI and verify all new authentication cases pass.**

### Task 3: Keep Docker healthy and document configuration

**Files:**
- Modify: `Dockerfile`
- Modify: `README.md`

- [ ] **Step 1: Make the health check use an unprotected local page so enabling `ZED_API_KEY` does not mark the container unhealthy.**
- [ ] **Step 2: Document the single environment variable and the two accepted request headers.**
- [ ] **Step 3: Run full CI including amd64, arm64, one-port smoke, login flow, and Web UI build.**
- [ ] **Step 4: Merge only after CI is green and verify the main Docker workflow successfully pushes `ghcr.io/handsomelong922/zed-api:latest`.**
