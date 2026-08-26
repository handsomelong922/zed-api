# Web API Key and Streaming Design

## Goal

Make the deployed Web UI the primary place to configure one global API key, persist it under `/data`, keep `ZED_API_KEY` only as a compatibility fallback, and restore reliable streaming for OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages in the final Docker runtime.

## API-key configuration

The server persists a Web-configured key in `/data/settings.json`. A non-empty persisted key takes precedence over `ZED_API_KEY`; if no persisted key exists, a non-empty environment value remains supported. The effective key is applied immediately without restarting the container.

The management API is intentionally outside `/v1/*` so an operator can configure the key from the existing Web console:

- `GET /zed/settings/api-key` returns only `enabled` and `source` (`none`, `file`, or `env`).
- `POST /zed/settings/api-key` accepts `{ "api_key": "..." }`, persists it, and switches authentication immediately.
- `DELETE /zed/settings/api-key` removes the persisted value and falls back to the environment value when present.

The saved secret is never returned by the API, rendered back into the Web page, or written to logs.

## Web UI

Add a Security/API Key settings page with a password input, show/hide control, status indicator, save button, and clear button. Saving clears the input after success. Service availability checks use an unprotected `/zed/*` endpoint instead of `/v1/models`, so enabling API authentication does not make the console appear offline.

## Streaming

The existing stream proxy already uses an external `curl -N` subprocess and contains protocol conversion code, but the final Alpine runtime currently lacks `curl`. Install `curl` in the runtime image. Harden outgoing SSE transport by using complete socket writes and headers that disable intermediary transformation/buffering (`Cache-Control: no-cache, no-transform` and `X-Accel-Buffering: no`).

Support these stream modes end-to-end:

- `POST /v1/chat/completions` with `stream:true`: OpenAI Chat Completion chunks followed by `data: [DONE]`.
- `POST /v1/responses` with `stream:true`: standard OpenAI Responses SSE events, preserving event types such as `response.output_text.delta` and `response.completed`.
- `POST /v1/messages` with `stream:true`: Anthropic Messages SSE events (`message_start`, content deltas, stop events).

Non-stream requests retain their existing behavior.

## Deployment constraints

Keep the existing single container port `8001`, the current 1Panel mapping model, account storage, and headless Zed/GitHub login flow unchanged. No browser or additional service is installed on the VPS.

## Verification

CI must prove the final Docker runtime contains `curl`, Web-saved keys apply immediately and survive container recreation on the same `/data` volume, clearing works, Web UI controls are embedded, and protocol-specific streaming framing/routing tests pass on Zig plus amd64/arm64 builds. Merge only after PR CI is green, then verify the `main` CI and multi-arch GHCR publish workflow for the merge commit.