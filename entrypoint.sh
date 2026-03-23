#!/bin/bash
set -e

# Generate host keys if not present (persisted via volume)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A
fi

# Start SSH daemon
/usr/sbin/sshd

echo "══════════════════════════════════════════════════"
echo "  Claude Sandbox is running"
echo "  Container: $(hostname)"
echo "══════════════════════════════════════════════════"

# Keep container alive
exec tail -f /dev/null
