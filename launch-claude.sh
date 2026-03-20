#!/bin/bash
set -euo pipefail

CONTAINER_NAME="claude-sandbox"
PROJECT_PATH="${1:-}"
SESSION_NAME="${2:-claude}"

if [ -z "$PROJECT_PATH" ]; then
    echo "Usage: ./launch-claude.sh <project-path> [tmux-session-name]"
    echo ""
    echo "Examples:"
    echo "  ./launch-claude.sh ~/Code/reminiscence"
    echo "  ./launch-claude.sh ~/Code/TENET tenet-dev"
    exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_PATH")"

# ─── Check container is running ─────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' is not running. Run ./setup.sh first."
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

# ─── Launch tmux + Claude inside container ──────────────
echo "→ Launching Claude in tmux session '${SESSION_NAME}'..."
ssh claude-sandbox "tmux new-session -d -s '${SESSION_NAME}' -c '/home/claude/workspace/${PROJECT_NAME}' 'claude --dangerously-skip-permissions' 2>/dev/null || true"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Claude is running in sandbox!"
echo ""
echo "  Attach to session:"
echo "    ssh -tt claude-sandbox \"bash -lic 'ta ${SESSION_NAME}'\""
echo ""
echo "  Or connect from Zed:"
echo "    Remote SSH → claude-sandbox"
echo "    Open terminal → ta ${SESSION_NAME}"
echo ""
echo "  Project is at: ~/workspace/${PROJECT_NAME}"
echo "══════════════════════════════════════════════════"
