#!/bin/bash
set -euo pipefail

CONTAINER_NAME="claude-sandbox"
PROJECT_NAME="${1:-}"
DEST="${2:-}"

if [ -z "$PROJECT_NAME" ]; then
    echo "Usage: ./sync-back.sh <project-name> [destination-path]"
    echo ""
    echo "Examples:"
    echo "  ./sync-back.sh reminiscence              # syncs to ~/Code/reminiscence"
    echo "  ./sync-back.sh reminiscence /tmp/review   # syncs to /tmp/review"
    exit 1
fi

DEST="${DEST:-$HOME/Code/${PROJECT_NAME}}"

echo "→ Syncing back: ${PROJECT_NAME} → ${DEST}"
docker cp "$CONTAINER_NAME:/home/claude/workspace/${PROJECT_NAME}" "$DEST"
echo "✓ Done. Review changes at: ${DEST}"
