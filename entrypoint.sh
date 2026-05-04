#!/bin/sh
# NanoClaw host entrypoint.
#
# Ensures the persistent-volume directories exist and are writable before
# handing off to the Node host process.  Railway mounts the volume at
# /app/data on every deploy; a fresh volume is an empty root-owned directory,
# so we create the required sub-paths here.
set -e

# ── Persistent-volume hygiene ──────────────────────────────────────────────
mkdir -p /app/data/v2-sessions
mkdir -p /app/logs
mkdir -p /app/store
mkdir -p /app/groups

# ── Start the host ─────────────────────────────────────────────────────────
# exec replaces this shell so tini (PID 1) forwards SIGTERM/SIGINT directly
# to Node, enabling the graceful-shutdown path in src/index.ts.
exec node /app/dist/index.js
