FROM alpine:3.20 AS builder

ARG ZIG_VERSION=0.15.2
RUN apk add --no-cache ca-certificates curl xz
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
RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.20 AS runtime
RUN apk add --no-cache ca-certificates
WORKDIR /data
COPY --from=builder /src/zig-out/bin/zed2api /usr/local/bin/zed2api

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8001/v1/models >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/zed2api"]
CMD ["serve", "8001"]
