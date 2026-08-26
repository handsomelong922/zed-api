# Main Web Headless Login Design

## Goal
Fix the main Web UI account-add flow for remote Docker / 1Panel deployments without adding ports or requiring GitHub login on the server.

## Root cause
The current `/zed/login` flow creates a random TCP listener inside the server/container, opens a Zed OAuth URL with that random `native_app_port`, sets global login state to `waiting`, and waits for the OAuth callback on the server's localhost. The user's browser is on a different machine, so Zed redirects the browser to the browser machine's `127.0.0.1:<random-port>` and the callback never reaches the server. The UI only polls `waiting`, so refreshes remain stuck and there is no recovery path.

## Design
1. Replace the main Web UI add-account OAuth flow with a headless flow using the same cryptographic pattern as the first-run `/login` helper.
2. `POST /zed/login` creates an in-memory RSA keypair, generates the Zed authorization URL, stores the pending account name and keypair, and returns the URL. It must not open a browser on the server and must not create or wait on a local TCP callback listener.
3. The Web UI opens the returned authorization URL in the user's local browser and immediately shows a completion form with instructions and a textarea for the final localhost callback URL.
4. Add `POST /zed/login/complete`. The server parses `user_id` and encrypted `access_token` from the pasted callback URL, decrypts the token using the in-memory pending RSA private key, saves the account, reloads the account manager, clears pending login state, and returns success.
5. Add `POST /zed/login/cancel`. It clears any pending keypair/account name and resets login state to idle. Starting a new login also replaces stale pending state rather than returning an unrecoverable 409.
6. `GET /zed/login/status` remains available, but `waiting` now means 'waiting for pasted callback URL', not 'waiting for a TCP callback'.
7. Keep the existing single external port. No new Docker ports, listeners, or reverse proxies are introduced.

## UI behavior
- Click Add Account -> optional account name -> server returns `login_url` -> local browser opens it.
- The modal remains open and shows: authorization instructions, callback URL textarea, Complete Import button, Cancel / Restart action.
- After Zed/GitHub redirects to `http://127.0.0.1:<port>/?user_id=...&access_token=...`, the failed page is expected. The user copies the full address-bar URL and pastes it into the modal.
- On successful import the modal closes, account list refreshes, and the new account appears.
- Refreshing the page while a login is pending must still allow the user to cancel/restart rather than being trapped in `waiting`.

## Error handling
- Missing or malformed callback URL: 400 with a precise error.
- Missing user_id / access_token: 400.
- Decryption failure or stale callback from an older login session: 400 and keep the UI recoverable.
- Cancel always releases the pending RSA keypair and account-name allocation.
- Starting a new login clears any stale pending state first.

## Tests
- Regression: current stuck-waiting behavior is reproduced before the fix.
- Server unit/integration tests cover callback parsing and pending-login state reset.
- CI smoke test proves the Web UI build succeeds and `/zed/login` no longer requires a server-side random callback listener.
- Existing Zig tests, Linux amd64/arm64 builds, one-port smoke tests, and Docker image builds must remain green.
