#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DIR="$SCRIPT_DIR/.instances"
SSH_KEY_DIR="$SCRIPT_DIR/.ssh"
BASE_PORT=2222

# ─── Defaults (override via env vars) ─────────────────────
SANDBOX_CPUS="${SANDBOX_CPUS:-4}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-8g}"
SANDBOX_BROWSER="${SANDBOX_BROWSER:-0}"
SANDBOX_CUDA="${SANDBOX_CUDA:-0}"
CUDA_BASE_IMAGE="nvidia/cuda:12.6.3-devel-ubuntu24.04"

# ─── Image selection ──────────────────────────────────────
IMAGE_NAME="claude-sandbox"
BASE_IMAGE="ubuntu:24.04"
GPU_ARGS=()
if [ "$SANDBOX_CUDA" = "1" ]; then
    IMAGE_NAME="${IMAGE_NAME}-cuda"
    BASE_IMAGE="$CUDA_BASE_IMAGE"
    # CDI, unlike --gpus, registers the GPUs in the container's device cgroup,
    # so a host `systemctl daemon-reload` doesn't revoke them.
    GPU_ARGS=(--device nvidia.com/gpu=all)
fi
if [ "$SANDBOX_BROWSER" = "1" ]; then
    BUILD_TARGET="browser"
    IMAGE_NAME="${IMAGE_NAME}-browser"
else
    BUILD_TARGET="base"
fi

# ─── Parse arguments ──────────────────────────────────────
INSTANCE_NAME="${1:-default}"
CONTAINER_NAME="claude-sandbox-${INSTANCE_NAME}"
SSH_HOST="sandbox-${INSTANCE_NAME}"

echo "═══ Claude Sandbox Setup: ${INSTANCE_NAME} ═══"
echo "  CPUs: ${SANDBOX_CPUS}  Memory: ${SANDBOX_MEMORY}  Browser: ${SANDBOX_BROWSER}  CUDA: ${SANDBOX_CUDA}"

# ─── 1. Generate SSH key pair (shared across instances) ────
mkdir -p "$SSH_KEY_DIR"

if [ ! -f "$SSH_KEY_DIR/sandbox_key" ]; then
    echo "→ Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/sandbox_key" -N "" -C "claude-sandbox"
    echo "✓ SSH key generated"
else
    echo "✓ SSH key already exists"
fi

# ─── 2. Build Docker image ─────────────────────────────────
echo "→ Building Docker image (target: ${BUILD_TARGET}, base: ${BASE_IMAGE})..."
docker build --target "$BUILD_TARGET" --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "✓ Image built: ${IMAGE_NAME}"

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
    "${GPU_ARGS[@]}" \
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
"$SCRIPT_DIR/sync-config.sh" "$INSTANCE_NAME"

# Add GitHub host key
docker exec -u claude "$CONTAINER_NAME" bash -c 'ssh-keyscan github.com >> /home/claude/.ssh/known_hosts 2>/dev/null'

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
