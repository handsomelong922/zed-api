# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM alpine:3.20 AS builder

ARG ZIG_VERSION=0.15.2
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl xz nodejs npm
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64) zig_arch="x86_64" ;; \
      aarch64) zig_arch="aarch64" ;; \
      *) echo "unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz

WORKDIR /src
COPY . .
RUN zig build test
RUN cd webui && npm ci && npm run build
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="$zig_target" -Doptimize=ReleaseSafe

FROM alpine:3.20 AS runtime
RUN apk add --no-cache openssl
ENV ZED_API_HOST=0.0.0.0
WORKDIR /data
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /src/zig-out/bin/zed2api /usr/local/bin/zed2api
COPY --from=builder /src/zig-out/bin/zed2api-setup /usr/local/bin/zed2api-setup
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8001/v1/models >/dev/null || wget -qO- http://127.0.0.1:8001/login >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
