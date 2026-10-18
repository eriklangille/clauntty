#!/bin/bash
# SSH test server using Apple's `container` (lightweight Linux VM per container),
# for Macs without Docker (e.g. the Mac mini). Same image as ssh-test-server.sh.
#
# Port publishing (-p) resets connections in container 1.4.1, so the server is
# reached on the container's own IP (192.168.64.x, only visible from this Mac;
# the iOS simulator shares the Mac's network, so Clauntty can connect to it).
#
# Usage:
#   ./container-ssh-server.sh start   - Start server, print host/credentials
#   ./container-ssh-server.sh stop    - Stop and remove the container
#   ./container-ssh-server.sh ip      - Print the container IP
#   ./container-ssh-server.sh test    - Test key auth

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_DIR="$SCRIPT_DIR/keys"
IMAGE_NAME="clauntty-ssh-test"
CONTAINER_NAME="clauntty-ssh"

container_ip() {
    container ls | awk -v n="$CONTAINER_NAME" '$1 == n && $5 == "running" {split($6, a, "/"); print a[1]}'
}

case "${1:-}" in
    start)
        container system status >/dev/null 2>&1 || container system start --enable-kernel-install

        if ! container image ls | awk '{print $1}' | grep -qx "$IMAGE_NAME"; then
            container build -t "$IMAGE_NAME" "$SCRIPT_DIR"
        fi

        if [ -z "$(container_ip)" ]; then
            container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
            container run -d --dns 1.1.1.1 --name "$CONTAINER_NAME" "$IMAGE_NAME" >/dev/null
            if [ -f "$KEY_DIR/test_key.pub" ]; then
                container exec -i "$CONTAINER_NAME" sh -c 'cat > /home/testuser/.ssh/authorized_keys &&
                    chown testuser:testuser /home/testuser/.ssh/authorized_keys &&
                    chmod 600 /home/testuser/.ssh/authorized_keys' < "$KEY_DIR/test_key.pub"
            fi
        fi

        echo "SSH test server running"
        echo "  Host: $(container_ip)  Port: 22"
        echo "  User: testuser  Password: testpass  (key: $KEY_DIR/test_key)"
        ;;
    stop)
        container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        echo "SSH test server stopped"
        ;;
    ip)
        container_ip
        ;;
    test)
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
            -i "$KEY_DIR/test_key" "testuser@$(container_ip)" echo "Key auth works!"
        ;;
    *)
        echo "Usage: $0 {start|stop|ip|test}"
        exit 1
        ;;
esac
