# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# ─── System packages ────────────────────────────────────
RUN apt-get update && apt-get install -y \
    openssh-server \
    tmux \
    git \
    curl \
    wget \
    ripgrep \
    fd-find \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    clang \
    ca-certificates \
    gnupg \
    sudo \
    locales \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# ─── Locale ─────────────────────────────────────────────
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ─── Create sandbox user ────────────────────────────────
RUN useradd -m -s /bin/bash -G sudo claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/claude

# ─── SSH server setup ───────────────────────────────────
RUN mkdir /var/run/sshd \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers claude" >> /etc/ssh/sshd_config \
    && sed -i 's/#AllowAgentForwarding yes/AllowAgentForwarding yes/' /etc/ssh/sshd_config

# ─── Install Rust, uv, Claude Code (as claude user) ─────
USER claude

# Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/home/claude/.cargo/bin:${PATH}"

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Bun (JavaScript runtime/bundler)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/claude/.bun/bin:${PATH}"

# Claude Code (native binary)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Persist PATH for interactive SSH sessions
RUN echo 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> /home/claude/.bashrc \
    && echo 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> /home/claude/.profile

# ─── Shell helpers (tmux) ────────────────────────────────
RUN cat >> /home/claude/.bashrc << 'BASHEOF'

# ─── tmux helpers ───────────────────────────────────────
ta() {
    local session="${1:-main}"
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux attach -t "$session"
    else
        tmux new-session -s "$session"
    fi
}
alias tl='tmux list-sessions 2>/dev/null && tmux list-windows -a 2>/dev/null || echo "No tmux sessions"'
alias tn='tmux new-session -s'

# ─── SSH agent forwarding fix for tmux ─────────────────
# New SSH connections update the symlink; all shells (including tmux) use it
if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/agent.sock" ]; then
    ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
BASHEOF
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /home/claude

# ─── SSH authorized keys + GitHub host key ───────────────
RUN mkdir -p /home/claude/.ssh && chmod 700 /home/claude/.ssh \
    && ssh-keyscan github.com >> /home/claude/.ssh/known_hosts 2>/dev/null

# ─── Claude config directory structure ──────────────────
RUN mkdir -p /home/claude/.claude/projects \
    /home/claude/.claude/skills \
    /home/claude/.claude/plugins \
    /home/claude/.claude/sessions

# ─── Workspace directory ────────────────────────────────
RUN mkdir -p /home/claude/workspace

# ─── Back to root for sshd startup ──────────────────────
USER root

# ─── System-wide PATH for all SSH session types ─────────
RUN echo 'PATH=/home/claude/.bun/bin:/home/claude/.local/bin:/home/claude/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > /etc/environment

EXPOSE 22

# ─── Entrypoint: start sshd, then keep alive ────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
