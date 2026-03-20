#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="claude-sandbox"
SSH_PORT=2222
IMAGE_NAME="claude-sandbox"

echo "═══ Claude Sandbox Setup ═══"

# ─── 1. Generate SSH key pair for sandbox ───────────────
SSH_KEY_DIR="$SCRIPT_DIR/.ssh"
mkdir -p "$SSH_KEY_DIR"

if [ ! -f "$SSH_KEY_DIR/sandbox_key" ]; then
    echo "→ Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/sandbox_key" -N "" -C "claude-sandbox"
    echo "✓ SSH key generated"
else
    echo "✓ SSH key already exists"
fi

# ─── 2. Build Docker image ─────────────────────────────
echo "→ Building Docker image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "✓ Image built"

# ─── 3. Stop existing container if running ──────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "→ Removing existing container..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
fi

# ─── 4. Start container ────────────────────────────────
echo "→ Starting container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname claude-sandbox \
    -p "${SSH_PORT}:22" \
    -v "$SSH_KEY_DIR/sandbox_key.pub:/home/claude/.ssh/authorized_keys:ro" \
    "$CONTAINER_NAME"
echo "✓ Container started"

# ─── 5. Wait for sshd to be ready ──────────────────────
echo "→ Waiting for SSH..."
for i in $(seq 1 10); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 \
        -i "$SSH_KEY_DIR/sandbox_key" -p "$SSH_PORT" claude@localhost echo "ok" 2>/dev/null; then
        break
    fi
    sleep 1
done
echo "✓ SSH ready"

# ─── 6. Sync git identity from host ──────────────────────
GIT_USER_NAME="$(git config --global user.name 2>/dev/null || echo '')"
GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || echo '')"
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    docker exec -u claude "$CONTAINER_NAME" git config --global user.name "$GIT_USER_NAME"
    docker exec -u claude "$CONTAINER_NAME" git config --global user.email "$GIT_USER_EMAIL"
    echo "✓ Git identity synced: $GIT_USER_NAME <$GIT_USER_EMAIL>"
fi

# ─── 7. Copy Claude config into container ──────────────
echo "→ Syncing Claude configuration..."

# Copy entire ~/.claude directory (skills, settings, plugins, CLAUDE.md)
docker cp "$HOME/.claude/CLAUDE.md" "$CONTAINER_NAME:/home/claude/.claude/CLAUDE.md"
docker cp "$HOME/.claude/settings.json" "$CONTAINER_NAME:/home/claude/.claude/settings.json"
# Remove pre-created dirs first to avoid nested copies (docker cp puts src INSIDE existing dst)
docker exec "$CONTAINER_NAME" rm -rf /home/claude/.claude/skills /home/claude/.claude/plugins
docker cp "$HOME/.claude/skills" "$CONTAINER_NAME:/home/claude/.claude/skills"
docker cp "$HOME/.claude/plugins" "$CONTAINER_NAME:/home/claude/.claude/plugins"

# Copy credentials (needed for Claude to authenticate)
docker cp "$HOME/.claude/.credentials.json" "$CONTAINER_NAME:/home/claude/.claude/.credentials.json"

# Copy tmux config
docker cp "$HOME/.tmux.conf" "$CONTAINER_NAME:/home/claude/.tmux.conf"

# Append tmux helpers (ta, tl, tn) to container's .bashrc
docker exec "$CONTAINER_NAME" bash -c 'cat >> /home/claude/.bashrc << '\''BASHEOF'\''

# ─── tmux helpers ───────────────────────────────────────
# ta: attach to default session (create if needed)
# ta <name>: attach to named session (create if needed)
ta() {
    local session="${1:-main}"
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux attach -t "$session"
    else
        tmux new-session -s "$session"
    fi
}

# tl: list all sessions with window names
alias tl='"'"'tmux list-sessions 2>/dev/null && tmux list-windows -a 2>/dev/null || echo "No tmux sessions"'"'"'

# tn: new named session
alias tn='"'"'tmux new-session -s'"'"'
BASHEOF'

# Add GitHub host key (so git push via SSH works without prompt)
docker exec -u claude "$CONTAINER_NAME" bash -c 'ssh-keyscan github.com >> /home/claude/.ssh/known_hosts 2>/dev/null'

# Fix ownership inside container
docker exec "$CONTAINER_NAME" chown -R claude:claude /home/claude/.claude /home/claude/.tmux.conf

echo "✓ Configuration synced"

# ─── 7. Setup SSH config on host ───────────────────────
SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q "Host claude-sandbox" "$SSH_CONFIG" 2>/dev/null; then
    echo "→ Adding SSH config entry..."
    mkdir -p "$HOME/.ssh"
    cat >> "$SSH_CONFIG" <<EOF

# Claude Code Sandbox Container
Host claude-sandbox
    HostName localhost
    Port ${SSH_PORT}
    User claude
    IdentityFile ${SSH_KEY_DIR}/sandbox_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel QUIET
    ForwardAgent yes
EOF
    chmod 600 "$SSH_CONFIG"
    echo "✓ SSH config added"
else
    echo "✓ SSH config entry already exists"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Connect via SSH:"
echo "    ssh claude-sandbox"
echo ""
echo "  Connect from Zed:"
echo "    Ctrl+Shift+P → 'remote: ssh connect'"
echo "    Select: claude-sandbox"
echo ""
echo "  Start Claude in sandbox:"
echo "    ./launch-claude.sh ~/Code/your-project"
echo "    ssh -tt claude-sandbox \"bash -lic 'ta claude'\""
echo ""
echo "  Mount your project (optional):"
echo "    docker cp /path/to/project ${CONTAINER_NAME}:/home/claude/workspace/"
echo "    docker exec ${CONTAINER_NAME} chown -R claude:claude /home/claude/workspace/"
echo "══════════════════════════════════════════════════"
