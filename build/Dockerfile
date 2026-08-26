FROM debian:bookworm-slim
COPY build.sh /build/build.sh
COPY pkg-overlay /build/pkg-overlay
COPY patches /build/patches
RUN chmod +x /build/build.sh
WORKDIR /build
ENTRYPOINT ["/build/build.sh"]