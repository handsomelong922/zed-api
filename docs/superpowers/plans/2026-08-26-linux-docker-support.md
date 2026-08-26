# Linux and Docker Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add low-overhead Linux amd64/arm64 binaries, a multi-architecture Docker image, and automated GitHub delivery without changing the proxy core.

**Architecture:** Keep the application bound to `127.0.0.1` and use Linux Docker host networking so containerized deployment reaches the host loopback without opening the service to the public network. Build with Zig 0.15.2 and use a minimal Alpine runtime image with `/data` as persistent working directory.

**Tech Stack:** Zig 0.15.2, Alpine Linux, Docker Buildx, GitHub Actions, GHCR.

---

### Task 1: Add minimal Docker runtime

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

- [ ] **Step 1: Add a multi-stage Dockerfile**

Use Alpine as both builder and runtime. Install Zig 0.15.2 only in the builder, run `zig build test`, build `ReleaseSafe`, copy only `zed2api` into the runtime, set `WORKDIR /data`, expose port 8001 for metadata, and add a localhost health check.

- [ ] **Step 2: Add `.dockerignore`**

Exclude Git metadata, build output, Node dependencies, logs, PID files, and `accounts.json` so credentials never enter the image build context.

- [ ] **Step 3: Validate Dockerfile structure**

Expected runtime contents: Alpine base, CA certificates, `/usr/local/bin/zed2api`; no Zig, Node, npm, Python, database, or relay process.

### Task 2: Add Linux CI and binary artifacts

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Add Ubuntu CI**

Install Zig 0.15.2 and run:

```sh
zig build test
```

Expected: exit code 0.

- [ ] **Step 2: Cross-build Linux binaries**

Run:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix zig-out/linux-amd64
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe --prefix zig-out/linux-arm64
```

Expected: both `zed2api` binaries exist.

- [ ] **Step 3: Upload both binaries as workflow artifacts**

Use `actions/upload-artifact@v4`.

### Task 3: Publish multi-architecture GHCR image

**Files:**
- Create: `.github/workflows/docker.yml`

- [ ] **Step 1: Configure Buildx and QEMU**

Target `linux/amd64` and `linux/arm64`.

- [ ] **Step 2: Authenticate to GHCR using `GITHUB_TOKEN`**

Grant only `contents: read` and `packages: write`.

- [ ] **Step 3: Publish image tags**

Publish `latest` on default branch, branch/tag refs, and SHA tags to:

```text
ghcr.io/handsomelong922/zed-api
```

### Task 4: Publish versioned Linux releases

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Trigger on `v*` tags**

- [ ] **Step 2: Cross-build amd64 and arm64 musl binaries**

- [ ] **Step 3: Package archives and checksums**

Produce:

```text
zed-api-linux-amd64.tar.gz
zed-api-linux-arm64.tar.gz
SHA256SUMS
```

- [ ] **Step 4: Attach files to a GitHub Release**

Use `softprops/action-gh-release@v2` with `contents: write`.

### Task 5: Document Linux deployment

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add Docker instructions for a 512 MB Linux VPS**

Use:

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

- [ ] **Step 2: Explain host networking**

State that the application remains on `127.0.0.1:8001`; Linux host networking is intentional to preserve the loopback-only security model without adding a proxy process.

- [ ] **Step 3: Add native Linux release instructions**

Document amd64/arm64 archives and direct execution.

- [ ] **Step 4: Add GHCR visibility note**

Explain that if the first GHCR package is private by default, the repository owner must change package visibility to Public once in GitHub Packages settings for anonymous `docker pull`.

### Task 6: Verify and integrate

**Files:**
- No new files unless CI fixes are required.

- [ ] **Step 1: Open a PR from `feature/linux-docker-support` to `main`**

- [ ] **Step 2: Inspect PR CI**

Expected: tests pass and both Linux binaries build.

- [ ] **Step 3: Fix any CI failures and rerun until green**

- [ ] **Step 4: Merge after verification**

- [ ] **Step 5: Inspect the `main` Docker workflow**

Expected: multi-arch image push succeeds.

- [ ] **Step 6: Verify image/package availability**

Confirm GHCR package exists. If anonymous pull is blocked only by package visibility, report the exact one-time visibility action instead of claiming a public image.
