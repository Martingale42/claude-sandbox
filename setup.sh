#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-sandbox"
INSTANCE_DIR="$SCRIPT_DIR/.instances"
SSH_KEY_DIR="$SCRIPT_DIR/.ssh"
BASE_PORT=2222

# ─── Defaults (override via env vars) ─────────────────────
SANDBOX_CPUS="${SANDBOX_CPUS:-4}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-8g}"

# ─── Parse arguments ──────────────────────────────────────
INSTANCE_NAME="${1:-default}"
CONTAINER_NAME="claude-sandbox-${INSTANCE_NAME}"
SSH_HOST="sandbox-${INSTANCE_NAME}"

echo "═══ Claude Sandbox Setup: ${INSTANCE_NAME} ═══"
echo "  CPUs: ${SANDBOX_CPUS}  Memory: ${SANDBOX_MEMORY}"

# ─── 1. Generate SSH key pair (shared across instances) ────
mkdir -p "$SSH_KEY_DIR"

if [ ! -f "$SSH_KEY_DIR/sandbox_key" ]; then
    echo "→ Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/sandbox_key" -N "" -C "claude-sandbox"
    echo "✓ SSH key generated"
else
    echo "✓ SSH key already exists"
fi

# ─── 2. Build Docker image (once, shared) ─────────────────
echo "→ Building Docker image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "✓ Image built"

# ─── 3. Resolve SSH port ──────────────────────────────────
mkdir -p "$INSTANCE_DIR"

if [ -f "$INSTANCE_DIR/${INSTANCE_NAME}" ]; then
    SSH_PORT=$(cat "$INSTANCE_DIR/${INSTANCE_NAME}")
    echo "✓ Reusing port ${SSH_PORT} for ${INSTANCE_NAME}"
else
    # Find next available port starting from BASE_PORT
    SSH_PORT=$BASE_PORT
    while ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} " || \
          [ -n "$(find "$INSTANCE_DIR" -type f -exec grep -l "^${SSH_PORT}$" {} + 2>/dev/null)" ]; do
        SSH_PORT=$((SSH_PORT + 1))
    done
    echo "$SSH_PORT" > "$INSTANCE_DIR/${INSTANCE_NAME}"
    echo "✓ Assigned port ${SSH_PORT} for ${INSTANCE_NAME}"
fi

# ─── 4. Stop existing container if running ─────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "→ Removing existing container..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
fi

# ─── 5. Start container with resource limits ───────────────
echo "→ Starting container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --cpus="$SANDBOX_CPUS" \
    --memory="$SANDBOX_MEMORY" \
    -p "${SSH_PORT}:22" \
    -v "$SSH_KEY_DIR/sandbox_key.pub:/home/claude/.ssh/authorized_keys:ro" \
    "$IMAGE_NAME"
echo "✓ Container started (cpus=${SANDBOX_CPUS}, memory=${SANDBOX_MEMORY})"

# ─── 6. Wait for sshd to be ready ─────────────────────────
echo "→ Waiting for SSH..."
for i in $(seq 1 10); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 \
        -i "$SSH_KEY_DIR/sandbox_key" -p "$SSH_PORT" claude@localhost echo "ok" 2>/dev/null; then
        break
    fi
    sleep 1
done
echo "✓ SSH ready"

# ─── 7. Sync git identity from host ───────────────────────
GIT_USER_NAME="$(git config --global user.name 2>/dev/null || echo '')"
GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || echo '')"
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    docker exec -u claude "$CONTAINER_NAME" git config --global user.name "$GIT_USER_NAME"
    docker exec -u claude "$CONTAINER_NAME" git config --global user.email "$GIT_USER_EMAIL"
    echo "✓ Git identity synced: $GIT_USER_NAME <$GIT_USER_EMAIL>"
fi

# ─── 8. Copy Claude config into container ──────────────────
echo "→ Syncing Claude configuration..."

docker cp "$HOME/.claude/CLAUDE.md" "$CONTAINER_NAME:/home/claude/.claude/CLAUDE.md"
docker cp "$HOME/.claude/settings.json" "$CONTAINER_NAME:/home/claude/.claude/settings.json"
docker exec "$CONTAINER_NAME" rm -rf /home/claude/.claude/skills /home/claude/.claude/plugins
docker cp "$HOME/.claude/skills" "$CONTAINER_NAME:/home/claude/.claude/skills"
docker cp "$HOME/.claude/plugins" "$CONTAINER_NAME:/home/claude/.claude/plugins"

docker cp "$HOME/.claude/.credentials.json" "$CONTAINER_NAME:/home/claude/.claude/.credentials.json"
docker cp "$HOME/.tmux.conf" "$CONTAINER_NAME:/home/claude/.tmux.conf"

# Add GitHub host key
docker exec -u claude "$CONTAINER_NAME" bash -c 'ssh-keyscan github.com >> /home/claude/.ssh/known_hosts 2>/dev/null'

# Fix ownership
docker exec "$CONTAINER_NAME" chown -R claude:claude /home/claude/.claude /home/claude/.tmux.conf

echo "✓ Configuration synced"

# ─── 9. Setup SSH config on host ──────────────────────────
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"

# Remove existing entry for this instance (marker-based)
if [ -f "$SSH_CONFIG" ]; then
    sed -i "/^# BEGIN ${SSH_HOST}$/,/^# END ${SSH_HOST}$/d" "$SSH_CONFIG"
fi

cat >> "$SSH_CONFIG" <<EOF
# BEGIN ${SSH_HOST}
Host ${SSH_HOST}
    HostName localhost
    Port ${SSH_PORT}
    User claude
    IdentityFile ${SSH_KEY_DIR}/sandbox_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel QUIET
    ForwardAgent yes
# END ${SSH_HOST}
EOF
chmod 600 "$SSH_CONFIG"
echo "✓ SSH config updated: ${SSH_HOST}"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Sandbox '${INSTANCE_NAME}' is ready!"
echo ""
echo "  Connect:  ssh ${SSH_HOST}"
echo "  Launch:   ./launch-claude.sh ${INSTANCE_NAME} ~/Code/your-project"
echo "  Attach:   ssh -tt ${SSH_HOST} \"bash -lic 'ta claude'\""
echo "  Resources: ${SANDBOX_CPUS} CPUs, ${SANDBOX_MEMORY} RAM"
echo ""
echo "  List all:  docker ps --filter name=claude-sandbox-"
echo "══════════════════════════════════════════════════"
