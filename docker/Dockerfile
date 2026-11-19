FROM eclipse-temurin:25-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /server
COPY server/ /server/
COPY scripts/ /opt/minecraft-server/scripts/
COPY README.md /opt/minecraft-server/README.md

ENV SERVER_DIR=/server \
    MEMORY=2G \
    PAPER_VERSION=26.3

EXPOSE 25565
STOPSIGNAL SIGTERM

ENTRYPOINT ["/opt/minecraft-server/scripts/start.sh"]
