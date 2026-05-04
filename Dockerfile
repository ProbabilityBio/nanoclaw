# ============================================================
# Stage 1 — builder
# Installs all dependencies (including native binaries for
# better-sqlite3) and compiles the host TypeScript source.
# ============================================================
FROM node:22-slim AS builder

WORKDIR /app

# Native build tools required by better-sqlite3
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Pin pnpm to the exact version declared in package.json#engines
ARG PNPM_VERSION=10.33.0
RUN npm install -g pnpm@${PNPM_VERSION}

# Install deps before copying source so Docker cache is reused on code-only changes
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# Compile TypeScript → dist/
COPY tsconfig.json ./
COPY src/ ./src/
RUN pnpm run build

# ============================================================
# Stage 2 — runner
# Minimal production image; only prod deps + compiled output.
# ============================================================
FROM node:22-slim AS runner

WORKDIR /app

# Runtime requirements:
#   - python3/make/g++  → better-sqlite3 must be rebuilt against the same
#                         Node ABI as the runner image
#   - docker-cli        → host spawns per-session agent containers
#   - tini              → PID 1 with correct signal forwarding
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
    docker.io \
    tini \
    && rm -rf /var/lib/apt/lists/*

ARG PNPM_VERSION=10.33.0
RUN npm install -g pnpm@${PNPM_VERSION}

# Production deps only
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile --prod

# Compiled host code
COPY --from=builder /app/dist ./dist

# Runtime assets the host reads at startup
COPY src/ ./src/
COPY container/ ./container/
COPY scripts/ ./scripts/
COPY setup/ ./setup/
COPY config-examples/ ./config-examples/

# Pre-create the directories that map to the persistent volume so the image
# works without a volume mount (dev / CI). The entrypoint re-creates them on
# every start in case Railway mounts a fresh empty volume over /app/data.
RUN mkdir -p /app/data/v2-sessions /app/logs /app/store /app/groups

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Railway / Docker maps this to $PORT via env; default is 3000
EXPOSE 3000

# Verify the health endpoint is responsive.
# start-period gives migrations + adapter init time to complete before
# the first health check fires.
HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD node -e "require('http').get('http://localhost:' + (process.env.PORT || process.env.WEBHOOK_PORT || 3000) + '/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

# tini as PID 1 → clean signal forwarding to the Node process
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
