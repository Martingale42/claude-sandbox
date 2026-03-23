#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DIR="$SCRIPT_DIR/.instances"

INSTANCE_NAME="${1:-}"
PROJECT_PATH="${2:-}"
SESSION_NAME="${3:-claude}"

if [ -z "$INSTANCE_NAME" ] || [ -z "$PROJECT_PATH" ]; then
    echo "Usage: ./launch-claude.sh <instance-name> <project-path> [tmux-session-name]"
    echo ""
    echo "Examples:"
    echo "  ./launch-claude.sh project-a ~/Code/project-a"
    echo "  ./launch-claude.sh project-b ~/Code/project-b dev"
    exit 1
fi

CONTAINER_NAME="claude-sandbox-${INSTANCE_NAME}"
SSH_HOST="sandbox-${INSTANCE_NAME}"
PROJECT_NAME="$(basename "$PROJECT_PATH")"

# ─── Check container is running ─────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' is not running. Run ./setup.sh ${INSTANCE_NAME} first."
    exit 1
fi

# ─── Sync project into container ────────────────────────
echo "→ Syncing project: ${PROJECT_NAME}..."
docker cp "$PROJECT_PATH" "$CONTAINER_NAME:/home/claude/workspace/${PROJECT_NAME}"
docker exec "$CONTAINER_NAME" chown -R claude:claude "/home/claude/workspace/${PROJECT_NAME}"
echo "✓ Project synced"

# ─── Re-sync credentials (in case they rotated) ────────
docker cp "$HOME/.claude/.credentials.json" "$CONTAINER_NAME:/home/claude/.claude/.credentials.json"
docker exec "$CONTAINER_NAME" chown claude:claude /home/claude/.claude/.credentials.json

# ─── Convert HTTPS git remotes to SSH (for agent forwarding) ──
ssh "$SSH_HOST" "cd /home/claude/workspace/${PROJECT_NAME} && \
    git remote -v 2>/dev/null | grep 'https://github.com' | awk '{print \$1}' | sort -u | while read remote; do \
        url=\$(git remote get-url \$remote); \
        new_url=\$(echo \$url | sed 's|https://github.com/|git@github.com:|'); \
        git remote set-url \$remote \$new_url; \
    done" 2>/dev/null || true

# ─── Launch tmux + Claude inside container ──────────────
echo "→ Launching Claude in tmux session '${SESSION_NAME}'..."
ssh "$SSH_HOST" "tmux new-session -d -s '${SESSION_NAME}' -c '/home/claude/workspace/${PROJECT_NAME}' 'claude --dangerously-skip-permissions' 2>/dev/null || true"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Claude is running in sandbox '${INSTANCE_NAME}'!"
echo ""
echo "  Attach to session:"
echo "    ssh -tt ${SSH_HOST} \"bash -lic 'ta ${SESSION_NAME}'\""
echo ""
echo "  Or connect from Zed:"
echo "    Remote SSH → ${SSH_HOST}"
echo "    Open terminal → ta ${SESSION_NAME}"
echo ""
echo "  Project is at: ~/workspace/${PROJECT_NAME}"
echo "══════════════════════════════════════════════════"
