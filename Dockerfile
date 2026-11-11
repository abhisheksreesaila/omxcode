# A mojoui.serve SaaS server (goal 66 M8): built by scripts/saas_image.sh from build/saas_image (never from the repo root).
# One process; host.db and tenants/ on the /data volume; the server checks its own health (no curl in the image).
FROM debian:trixie-slim
ARG APP=examples/finance_min
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata libsqlite3-0 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /data saas && mkdir -p /data && chown saas /data
COPY rootfs/app /app
ENV SAAS_DATA=/data SAAS_HOST=0.0.0.0 SAAS_PORT=8000 FIN_ROOT=/app/${APP} SAAS_STATIC=/app/${APP}/static TZDIR=/usr/share/zoneinfo
WORKDIR /app
USER saas
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=4s --start-period=5s --retries=3 CMD ["/bin/sh", "-c", "/app/server --health http://127.0.0.1:${SAAS_PORT}/health"]
ENTRYPOINT ["/app/server"]
