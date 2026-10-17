# Project Long Colt dedicated server (docs/net/servers.md).
# Build from the project root after exporting the Linux build (build/linux/):
#   docker build -f tools/server/Dockerfile -t longcolt-server .
# Run with a config volume and the game port (UDP):
#   docker run -d --name longcolt -p 7777:7777/udp -v longcolt-config:/config longcolt-server
FROM debian:bookworm-slim

# The exported binary only links glibc, which the base image has.
RUN useradd --create-home --home-dir /home/longcolt --shell /usr/sbin/nologin longcolt \
    && mkdir -p /config && chown longcolt:longcolt /config

COPY --chmod=755 ["build/linux/Project Long Colt.x86_64", "/opt/longcolt/longcolt.x86_64"]

USER longcolt
WORKDIR /home/longcolt
VOLUME ["/config"]
EXPOSE 7777/udp

# First start with an empty /config volume: the server writes the example config there, logs it,
# and runs with it. Edit /config/server.cfg and restart the container to change it.
ENTRYPOINT ["/opt/longcolt/longcolt.x86_64", "--headless", "--", "--server", "--server-config", "/config/server.cfg"]
