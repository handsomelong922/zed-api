# ZED_API_KEY Authentication Design

## Goal
Add one optional global API key configured by the `ZED_API_KEY` environment variable, without changing ports, addresses, or the Zed/GitHub login flow.

## Behavior
- If `ZED_API_KEY` is unset or empty, preserve the current unauthenticated API behavior.
- If `ZED_API_KEY` is non-empty, require it for model/compatibility API routes: `/v1/*` and `/api/event_logging/batch`.
- Accept either `Authorization: Bearer <key>` or `x-api-key: <key>` so OpenAI-style and Anthropic-style clients can use the same key.
- Missing or incorrect credentials return HTTP 401 with a JSON error and do not reach provider routing.
- Do not protect `/`, `/login`, or `/zed/*`; this change is specifically API-call authentication and must not alter the existing Web UI/account-login workflow.
- Never log or return the configured key.

## Deployment
Set `ZED_API_KEY` in the container environment from 1Panel. The Docker health check must remain healthy when the key is enabled.

## Verification
Docker smoke tests cover disabled auth, missing/wrong credentials, Bearer authentication, and `x-api-key` authentication. Existing one-port, login, amd64, arm64, and Web UI tests must continue to pass.
