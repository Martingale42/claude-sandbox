#!/bin/bash
set -euo pipefail

INSTANCE_NAME="${1:-}"

if [ -z "$INSTANCE_NAME" ]; then
    echo "Usage: ./sync-config.sh <instance-name>"
    echo ""
    echo "Copies the host's Claude config (CLAUDE.md, settings.json, skills, plugins,"
    echo "hooks, credentials) and ~/.tmux.conf into a running sandbox."
    exit 1
fi

CONTAINER_NAME="claude-sandbox-${INSTANCE_NAME}"
CONTAINER_HOME="/home/claude"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' is not running. Run ./setup.sh ${INSTANCE_NAME} first."
    exit 1
fi

echo "→ Syncing Claude configuration..."

docker cp "$HOME/.claude/CLAUDE.md" "$CONTAINER_NAME:$CONTAINER_HOME/.claude/CLAUDE.md"
docker exec "$CONTAINER_NAME" rm -rf "$CONTAINER_HOME/.claude/skills" "$CONTAINER_HOME/.claude/plugins" "$CONTAINER_HOME/.claude/hooks"

# Skills are often symlinks into a checkout outside ~/.claude, so copy their targets
docker exec "$CONTAINER_NAME" mkdir -p "$CONTAINER_HOME/.claude/skills"
tar -chf - -C "$HOME/.claude/skills" . | docker exec -i "$CONTAINER_NAME" tar -xf - -C "$CONTAINER_HOME/.claude/skills"
docker cp "$HOME/.claude/plugins" "$CONTAINER_NAME:$CONTAINER_HOME/.claude/plugins"
if [ -d "$HOME/.claude/hooks" ]; then
    docker cp "$HOME/.claude/hooks" "$CONTAINER_NAME:$CONTAINER_HOME/.claude/hooks"
fi

docker cp "$HOME/.claude/.credentials.json" "$CONTAINER_NAME:$CONTAINER_HOME/.claude/.credentials.json"
docker cp "$HOME/.tmux.conf" "$CONTAINER_NAME:$CONTAINER_HOME/.tmux.conf"

# ─── settings.json: map host paths into the container ────
# Hook commands name scripts by absolute host path, so point them at the
# container home and drop any hook whose script still isn't there: a missing
# UserPromptSubmit script exits 2, which Claude Code reads as "block the prompt".
SETTINGS_TMP="$(mktemp)"
trap 'rm -f "$SETTINGS_TMP"' EXIT
sed "s|$HOME/|$CONTAINER_HOME/|g" "$HOME/.claude/settings.json" > "$SETTINGS_TMP"

MISSING_PATHS="$(jq -r '.hooks // {} | .[][].hooks[].command // empty' "$SETTINGS_TMP" \
    | { grep -o "$CONTAINER_HOME/[^\"' ;|&)]*" || true; } | sort -u \
    | while read -r path; do
        docker exec "$CONTAINER_NAME" test -e "$path" || echo "$path"
    done)"

if [ -n "$MISSING_PATHS" ]; then
    echo "$MISSING_PATHS" | sed 's/^/  ⚠ dropping hook, not in container: /'
    jq --arg missing "$MISSING_PATHS" '
        ($missing | split("\n")) as $gone
        | .hooks |= (
            map_values(
                map(.hooks |= map(select(
                    (.command // "") as $cmd | all($gone[]; . as $p | $cmd | contains($p) | not)
                )))
                | map(select(.hooks | length > 0))
            )
            | with_entries(select(.value | length > 0))
        )' "$SETTINGS_TMP" > "$SETTINGS_TMP.new"
    mv "$SETTINGS_TMP.new" "$SETTINGS_TMP"
fi

docker cp "$SETTINGS_TMP" "$CONTAINER_NAME:$CONTAINER_HOME/.claude/settings.json"

docker exec "$CONTAINER_NAME" chown -R claude:claude "$CONTAINER_HOME/.claude" "$CONTAINER_HOME/.tmux.conf"

echo "✓ Configuration synced"
