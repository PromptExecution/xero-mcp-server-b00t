# Xero MCP Server — justfile
# 12-factor: config from environment, build once run anywhere
# Requires: node, npm, just

set dotenv-load := true
set dotenv-filename := ".env"
set tempdir := "/tmp"
# Keep just's temp files under /tmp so sandboxed runs aren't blocked by /run/user/1000/just being read-only.

export NODE_ENV := env_var_or_default("NODE_ENV", "development")

PID_FILE := ".server.pid"
LOG_FILE := ".server.log"

# List available recipes
default:
    @just --list

# Install dependencies
install:
    npm install

# Compile TypeScript → dist/
build:
    npm run build

# Build (if needed) then start the MCP server in the background
start: _require-env
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f "{{PID_FILE}}" ]; then
        PID=$(cat "{{PID_FILE}}")
        if kill -0 "$PID" 2>/dev/null; then
            echo "Server already running (PID $PID)"
            exit 0
        fi
        rm -f "{{PID_FILE}}"
    fi
    if [ ! -f dist/index.js ]; then
        echo "dist/index.js not found — building first..."
        npm run build
    fi
    nohup node dist/index.js >> "{{LOG_FILE}}" 2>&1 &
    echo $! > "{{PID_FILE}}"
    echo "Server started (PID $(cat {{PID_FILE}}))"
    echo "Logs → {{LOG_FILE}}"

# Stop the background server
stop:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{PID_FILE}}" ]; then
        echo "No PID file found — server may not be running"
        exit 0
    fi
    PID=$(cat "{{PID_FILE}}")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        rm -f "{{PID_FILE}}"
        echo "Server stopped (PID $PID)"
    else
        echo "Process $PID not running — cleaning up PID file"
        rm -f "{{PID_FILE}}"
    fi

# Show server status and tail logs
status:
    #!/usr/bin/env bash
    if [ -f "{{PID_FILE}}" ]; then
        PID=$(cat "{{PID_FILE}}")
        if kill -0 "$PID" 2>/dev/null; then
            echo "Server is running (PID $PID)"
        else
            echo "Server is NOT running (stale PID $PID)"
        fi
    else
        echo "Server is NOT running"
    fi
    if [ -f "{{LOG_FILE}}" ]; then
        echo ""
        echo "--- Last 20 log lines ---"
        tail -20 "{{LOG_FILE}}"
    fi

# Tail logs live
logs:
    tail -f "{{LOG_FILE}}"

# Stop, rebuild, and restart
restart: stop build start

# Run interactively in foreground (for debugging / MCP client use)
run: _require-env
    node dist/index.js

# Lint the source
lint:
    npm run lint

# Clean build artifacts and PID/log files
clean: stop
    rm -rf dist "{{LOG_FILE}}"

# Guard: ensure required env vars are set
_require-env:
    #!/usr/bin/env bash
    missing=()
    [ -z "${XERO_CLIENT_ID:-}" ]     && missing+=("XERO_CLIENT_ID")
    [ -z "${XERO_CLIENT_SECRET:-}" ] && missing+=("XERO_CLIENT_SECRET")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required environment variables: ${missing[*]}"
        echo "Copy .env.example → .env and fill in your credentials."
        exit 1
    fi
