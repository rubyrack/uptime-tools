# linux/amd64 only (SteamCMD and the server depot are x86_64).
# The server is installed from Steam at container start, not here.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/rubyrack/uptime-tools" \
      org.opencontainers.image.description="Uptime dedicated server"

ARG PLAYIT_VERSION=v1.0.10
ARG PINGGY_VERSION=v0.5.6

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl tini lib32gcc-s1 lib32stdc++6 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --retry 3 -o /usr/local/bin/playit \
        "https://github.com/playit-cloud/playit-agent/releases/download/${PLAYIT_VERSION}/playit-linux-amd64" \
 && curl -fsSL --retry 3 -o /usr/local/bin/pinggy \
        "https://github.com/Pinggy-io/cli-js/releases/download/${PINGGY_VERSION}/pinggy-linux-x64" \
 && chmod 0755 /usr/local/bin/playit /usr/local/bin/pinggy

RUN useradd --create-home --home-dir /home/uptime --shell /bin/sh --uid 1000 uptime \
 && mkdir -p /data && chown uptime:uptime /data
USER uptime
WORKDIR /home/uptime

RUN mkdir -p steamcmd \
 && curl -fsSL --retry 3 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C steamcmd

COPY --chown=uptime:uptime entrypoint.sh /home/uptime/entrypoint.sh
COPY --chown=uptime:uptime tunnels/ /home/uptime/tunnels/
RUN chmod 0755 /home/uptime/entrypoint.sh /home/uptime/tunnels/*.sh

ENV SteamAppId=4813880 \
    HOME=/home/uptime \
    UPTIME_DATA_DIR=/data

VOLUME ["/data"]
EXPOSE 27016/udp
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD [ "${UPTIME_HTTP_PORT:-9875}" = "0" ] || curl -fsS "http://127.0.0.1:${UPTIME_HTTP_PORT:-9875}/health" >/dev/null

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/home/uptime/entrypoint.sh"]
CMD []
