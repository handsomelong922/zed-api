# Linux and Docker Support Design

## Goal

Add a low-overhead Linux deployment path for `zed-api` that works well on a 512 MB VPS, while preserving the existing loopback-only security model and avoiding changes to the protocol proxy core.

## Architecture

The native Zig application already builds against a standard target and only links Windows-specific libraries on Windows. Linux support therefore does not require protocol or server changes. Native Linux binaries will be produced for amd64 and arm64 with Zig targeting musl.

For Docker on Linux, the container will run the existing binary with `--network host`. Because `zed2api` intentionally binds `127.0.0.1`, host networking makes that loopback listener available on the Linux host without changing the application to listen on all interfaces. This avoids an extra TCP relay process, preserves the current security boundary, and keeps runtime overhead minimal.

The container runtime image will contain only Alpine, CA certificates, and the compiled `zed2api` binary. Account state remains relative to the working directory, so `/data` is the working directory and is intended to be mounted as a persistent volume.

## CI/CD

GitHub Actions will provide three workflows:

1. `CI`: run `zig build test`, cross-build Linux amd64/arm64 binaries, and upload them as workflow artifacts.
2. `Docker`: build and publish a multi-architecture image to `ghcr.io/handsomelong922/zed-api` on pushes to `main` and version tags.
3. `Release Linux binaries`: on `v*` tags, build amd64/arm64 musl binaries, package them, generate SHA256 checksums, and attach them to a GitHub Release.

## Deployment

Recommended Docker deployment on the 512 MB VPS:

```sh
mkdir -p data
docker run -d \
  --name zed-api \
  --restart unless-stopped \
  --memory=384m \
  --network host \
  -v "$PWD/data:/data" \
  ghcr.io/handsomelong922/zed-api:latest
```

The API remains reachable only on `127.0.0.1:8001` unless the operator explicitly places an authenticated reverse proxy, VPN, or tunnel in front of it.

## Security

No API authentication is added in this change. The service continues to bind only to loopback. Docker documentation must explicitly require Linux host networking and must warn against exposing the API through an unauthenticated public reverse proxy.

## Compatibility

Existing Windows and macOS behavior remains unchanged. Protocol conversion, streaming, tool calling, account scheduling, OAuth, and Web UI code are not modified.

## Verification

The change is accepted when:

- `zig build test` passes on Ubuntu in GitHub Actions.
- Linux amd64 and arm64 binaries are produced.
- Docker multi-arch build succeeds for `linux/amd64` and `linux/arm64`.
- A PR from the feature branch passes CI.
- After merge to `main`, the GHCR workflow publishes the image.
