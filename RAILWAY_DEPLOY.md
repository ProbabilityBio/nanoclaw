# Deploying NanoClaw to Railway

This guide covers every step to get a production NanoClaw instance running on Railway.

---

## Architecture overview

NanoClaw runs as a single Node.js host process that spawns short-lived Docker containers for each agent session. On Railway this means:

| Component | Where it runs |
|-----------|--------------|
| **Host** (Node.js) | Railway service — this Dockerfile |
| **Agent containers** | Spawned by the host via the Docker socket (see below) |
| **Central DB** (`data/v2.db`) | Railway Volume mounted at `/app/data` |
| **Session DBs** (`data/v2-sessions/…`) | Same volume |
| **OneCLI vault** | Separate Railway service or external host |

---

## Prerequisites

- A Railway account (Pro or Team plan recommended for Docker socket access)
- A Railway project
- Docker image for the agent container pre-built and pushed to a registry (see [Building the agent image](#building-the-agent-image))

---

## Step 1 — Create the Railway service

1. In your Railway project, click **+ New → Empty Service**.
2. Connect the service to your GitHub repo (or push via Railway CLI).
3. Railway auto-detects the root `Dockerfile` and uses it.

---

## Step 2 — Mount the persistent volume

**All SQLite data lives under `/app/data`. This directory MUST be backed by a Railway Volume — if it isn't, every redeploy loses all users, groups, sessions, and conversation history.**

1. In the Railway dashboard, open your service → **Volumes** tab.
2. Click **+ New Volume**.
3. Set the **Mount Path** to `/app/data`.
4. Save. Railway provisions the volume and mounts it at that path on every deploy.

The `entrypoint.sh` runs `mkdir -p /app/data/v2-sessions` and the other sub-directories on every start, so a brand-new volume is safe.

---

## Step 3 — Docker socket access (required for agent containers)

NanoClaw's host spawns per-session agent containers via `docker run`. On Railway this requires one of the following:

### Option A — Privileged mode + Docker-in-Docker (simplest)

1. Go to your service → **Settings** → scroll to **Deploy**.
2. Enable **Privileged**.
3. Add the Docker daemon as a sidecar or use the `docker:dind` image pattern.

> **Note:** Privileged mode is available on Railway Pro/Team plans.

### Option B — Mount the host Docker socket

If Railway exposes the host socket (check their latest docs), add a volume-style bind mount at `/var/run/docker.sock`. This is less isolated but avoids DinD overhead.

### Option C — External Docker host

Set `DOCKER_HOST=tcp://your-docker-host:2376` and point the host at a remote Docker daemon (e.g., a dedicated VM).

---

## Step 4 — Set environment variables

In your service → **Variables**, add the following. Use Railway's secret management — do NOT commit a `.env` file with real values.

| Variable | Required | Notes |
|----------|----------|-------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | From `claude auth login` → `~/.claude/.credentials.json` |
| `ONECLI_URL` | Yes if using OneCLI | Internal Railway URL of your OneCLI service |
| `ONECLI_API_KEY` | Yes if using OneCLI | OneCLI gateway API key |
| `WEBHOOK_PORT` | No | Defaults to `3000`. Railway injects `$PORT` — either works |
| `ASSISTANT_NAME` | No | Default: `Andy` |
| `CONTAINER_RUNTIME` | No | Default: `docker` |
| `MAX_CONCURRENT_CONTAINERS` | No | Default: `5` — reduce if you hit memory limits |
| `LOG_LEVEL` | No | Default: `info` |
| `TZ` | No | IANA timezone, e.g. `America/New_York` |

See `.env.example` for the full list with descriptions.

---

## Step 5 — Building the agent image

The agent container (`container/Dockerfile`) runs Bun, Claude Code CLI, Chromium, and other heavy dependencies. You must build and push it to a container registry **before** your first deploy, then tell the host where to find it.

```bash
# From your local machine (or a CI job):
cd /path/to/nanoclaw

# Build the agent image
./container/build.sh

# Tag and push to your registry (e.g. Docker Hub or GHCR)
docker tag nanoclaw-agent:latest ghcr.io/YOUR_ORG/nanoclaw-agent:latest
docker push ghcr.io/YOUR_ORG/nanoclaw-agent:latest
```

Then set the Railway variable:

```
CONTAINER_IMAGE=ghcr.io/YOUR_ORG/nanoclaw-agent:latest
```

The host reads `CONTAINER_IMAGE` and uses it for every `docker run` call instead of the local `nanoclaw-agent:latest` tag.

---

## Step 6 — Deploy

Push your changes to the connected branch (or run `railway up`). Railway will:

1. Detect the root `Dockerfile`.
2. Run the multi-stage build (deps → TypeScript compile → lean runtime image).
3. Mount the `/app/data` volume.
4. Start the container via `entrypoint.sh`.
5. Poll `GET /health` — the service is marked healthy once it returns `200`.

---

## Step 7 — Bootstrap the first agent

Once the service is healthy, open a Railway shell or use the `/init-first-agent` skill from your connected chat channel to create the first DM-wired agent.

Alternatively, from the Railway shell:

```bash
node scripts/init-first-agent.js
```

---

## Health check

The host exposes `GET /health` on the webhook port (default `3000`). The response is:

```json
{ "status": "ok", "uptime": 42.3 }
```

`railway.json` sets `healthcheckPath: "/health"` with a 300-second timeout to allow for DB migrations and adapter init on first boot.

---

## Logs

| What | Where |
|------|-------|
| Host stdout/stderr | Railway dashboard → **Logs** tab |
| Error log | `/app/logs/nanoclaw.error.log` (persists on volume if you extend `entrypoint.sh` to write logs there) |
| Container logs | Lost on container exit (`--rm`). Capture with `DOCKER_HOST` logging driver if needed. |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Service loops restarting | Circuit breaker triggered (5+ rapid restarts) | Check Railway logs for startup error; the host backs off exponentially |
| `/health` returns 404 | Old image without health endpoint | Rebuild and redeploy |
| `docker: command not found` inside container | Docker CLI not on `$PATH` | Verify `docker.io` is installed in the Dockerfile runner stage |
| Agent containers don't start | Docker socket not accessible | Check privileged mode / socket mount |
| DB locked errors | Two replicas writing to same SQLite file | Set `numReplicas: 1` in `railway.json` (SQLite is single-writer) |
| `401 Unauthorized` from APIs | OneCLI agent in `selective` mode | Run `onecli agents set-secret-mode --id <id> --mode all` |

---

## Scaling note

NanoClaw uses SQLite (single-writer). Keep `numReplicas: 1` in `railway.json`. Horizontal scaling requires migrating to a multi-writer DB — that's a future project milestone, not a config change.
