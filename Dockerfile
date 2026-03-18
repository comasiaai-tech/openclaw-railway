# Install OpenClaw from npm for Railway
# Pulls latest stable release automatically

FROM node:22-bookworm

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Install utilities
RUN apt-get update && apt-get install -y --no-install-recommends jq openssl && \
    rm -rf /var/lib/apt/lists/*

# Create persistent directories
RUN mkdir -p /data/.openclaw /data/workspace

# Copy startup script
COPY railway-entrypoint.sh /app/railway-entrypoint.sh
RUN chmod +x /app/railway-entrypoint.sh

# Defaults
ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace

EXPOSE ${PORT:-8080}
ENTRYPOINT ["/app/railway-entrypoint.sh"]
