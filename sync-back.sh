#!/bin/bash
set -euo pipefail

INSTANCE_NAME="${1:-}"
PROJECT_NAME="${2:-}"
DEST="${3:-}"

if [ -z "$INSTANCE_NAME" ] || [ -z "$PROJECT_NAME" ]; then
    echo "Usage: ./sync-back.sh <instance-name> <project-name> [destination-path]"
    echo ""
    echo "Examples:"
    echo "  ./sync-back.sh project-a my-project              # syncs to ~/Code/my-project"
    echo "  ./sync-back.sh project-b my-project /tmp/review   # syncs to /tmp/review"
    exit 1
fi

CONTAINER_NAME="claude-sandbox-${INSTANCE_NAME}"
DEST="${DEST:-$HOME/Code/${PROJECT_NAME}}"

echo "→ Syncing back: ${CONTAINER_NAME}:${PROJECT_NAME} → ${DEST}"
docker cp "$CONTAINER_NAME:/home/claude/workspace/${PROJECT_NAME}" "$DEST"
echo "✓ Done. Review changes at: ${DEST}"
