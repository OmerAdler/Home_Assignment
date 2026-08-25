# Containerfile — installs the .deb from Part 1 into a minimal Debian base and
# reproduces nginx:1.25-bookworm's runtime behavior exactly.
FROM debian:bookworm-slim

# Runtime-only dependencies (matches the .deb's own Depends:) — no compiler toolchain here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libssl3 libpcre2-8-0 zlib1g ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Same nginx system account as the upstream image — verified byte-for-byte against
# `grep nginx /etc/passwd /etc/group` on the real image (uid/gid 101, no shell, no home).
RUN groupadd --system --gid 101 nginx \
    && useradd --system --no-create-home --home-dir /nonexistent \
       --gid nginx --shell /bin/false --uid 101 --comment "nginx user" nginx

ARG NGINX_VERSION=1.25.5
ARG PKG_REVISION=1echo1
COPY dist/nginx-echo_${NGINX_VERSION}-${PKG_REVISION}_amd64.deb /tmp/nginx-echo.deb
RUN dpkg -i /tmp/nginx-echo.deb && rm -f /tmp/nginx-echo.deb

# Container-only runtime scaffolding, copied verbatim from nginx:1.25-bookworm (Step 1b) —
# not part of the .deb, because a real Debian install of this package wouldn't have these.
COPY container/rootfs/docker-entrypoint.sh /docker-entrypoint.sh
COPY container/rootfs/docker-entrypoint.d/ /docker-entrypoint.d/
RUN chmod +x /docker-entrypoint.sh /docker-entrypoint.d/*.sh \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

STOPSIGNAL SIGQUIT
EXPOSE 80
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]