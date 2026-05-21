# Icecast 2 — Railway-compatible Dockerfile
#
# Build context must be the repo root so icecast.xml is accessible:
#   docker build -f icecast/Dockerfile .
#
# On Railway:
#   - Set "Root Directory" to / (repo root)
#   - Set "Dockerfile Path" to icecast/Dockerfile
#   - Add env var PORT=8000 to this service
#   - Name the service "icecast" so other services can reach it via
#     icecast.railway.internal:8000 on the private network.

FROM debian:bookworm-slim

# Prevent interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    # Tell the icecast2 postinst not to run interactive config
    && echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections \
    && apt-get install -y --no-install-recommends icecast2 \
    && rm -rf /var/lib/apt/lists/* \
    # The postinst may skip user creation when running non-interactively;
    # create the system user/group explicitly as a fallback.
    && (getent group  icecast2 || addgroup  --system icecast2) \
    && (getent passwd icecast2 || adduser --system --ingroup icecast2 --no-create-home icecast2) \
    && mkdir -p /var/log/icecast2 /run/icecast2 \
    && chown -R icecast2:icecast2 /var/log/icecast2 /run/icecast2

# Copy config from repo root
COPY --chown=icecast2:icecast2 icecast.xml /etc/icecast2/icecast.xml

# Railway routes public traffic to $PORT.
# Set PORT=8000 in Railway env vars so it matches what Icecast listens on.
ENV PORT=8000
EXPOSE 8000

# Run as non-root — Icecast2 refuses to start as root
USER icecast2

CMD ["icecast2", "-c", "/etc/icecast2/icecast.xml"]
