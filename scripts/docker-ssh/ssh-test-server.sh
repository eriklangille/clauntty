#!/bin/bash
# SSH Test Server management script for Clauntty
#
# Usage:
#   ./ssh-test-server.sh start    - Build and start the SSH server
#   ./ssh-test-server.sh stop     - Stop the SSH server
#   ./ssh-test-server.sh status   - Check if server is running
#   ./ssh-test-server.sh keygen   - Generate SSH key pair for testing
#   ./ssh-test-server.sh test     - Test SSH connection
#   ./ssh-test-server.sh logs     - Show container logs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="clauntty-ssh-test"
IMAGE_NAME="clauntty-ssh-test"
SSH_PORT=${SSH_PORT:-22}  # Default to 22, can override with SSH_PORT=2222
KEY_DIR="$SCRIPT_DIR/keys"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

case "$1" in
    start)
        echo -e "${GREEN}Building SSH test server...${NC}"
        docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

        # Stop existing container if running
        docker rm -f "$CONTAINER_NAME" 2>/dev/null

        # Generate keys if they don't exist
        if [ ! -f "$KEY_DIR/test_key" ]; then
            echo -e "${YELLOW}Generating SSH key pair...${NC}"
            mkdir -p "$KEY_DIR"
            ssh-keygen -t ed25519 -f "$KEY_DIR/test_key" -N "" -C "clauntty-test"
        fi

        # Create authorized_keys file
        mkdir -p "$KEY_DIR"
        cp "$KEY_DIR/test_key.pub" "$KEY_DIR/authorized_keys" 2>/dev/null || true

        echo -e "${GREEN}Starting SSH test server on port $SSH_PORT...${NC}"
        docker run -d \
            --name "$CONTAINER_NAME" \
            -p "$SSH_PORT:22" \
            -v "$KEY_DIR/authorized_keys:/home/testuser/.ssh/authorized_keys:ro" \
            "$IMAGE_NAME"

        # Fix permissions inside container
        docker exec "$CONTAINER_NAME" chown testuser:testuser /home/testuser/.ssh/authorized_keys 2>/dev/null || true
        docker exec "$CONTAINER_NAME" chmod 600 /home/testuser/.ssh/authorized_keys 2>/dev/null || true

        echo ""
        echo -e "${GREEN}SSH Test Server is running!${NC}"
        echo "=================================="
        echo -e "Host: ${YELLOW}localhost${NC}"
        echo -e "Port: ${YELLOW}$SSH_PORT${NC}"
        echo -e "Username: ${YELLOW}testuser${NC}"
        echo -e "Password: ${YELLOW}testpass${NC}"
        echo ""
        echo "SSH Key (for key auth):"
        echo -e "  Private key: ${YELLOW}$KEY_DIR/test_key${NC}"
        echo -e "  Public key:  ${YELLOW}$KEY_DIR/test_key.pub${NC}"
        echo ""
        echo "Test with:"
        echo -e "  ${YELLOW}ssh -p $SSH_PORT testuser@localhost${NC}"
        echo -e "  ${YELLOW}ssh -p $SSH_PORT -i $KEY_DIR/test_key testuser@localhost${NC}"
        ;;

    stop)
        echo -e "${YELLOW}Stopping SSH test server...${NC}"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}Stopped.${NC}"
        ;;

    status)
        if docker ps | grep -q "$CONTAINER_NAME"; then
            echo -e "${GREEN}SSH test server is running on port $SSH_PORT${NC}"
            docker ps | grep "$CONTAINER_NAME"
        else
            echo -e "${RED}SSH test server is not running${NC}"
        fi
        ;;

    keygen)
        echo -e "${GREEN}Generating new SSH key pair...${NC}"
        mkdir -p "$KEY_DIR"
        rm -f "$KEY_DIR/test_key" "$KEY_DIR/test_key.pub"
        ssh-keygen -t ed25519 -f "$KEY_DIR/test_key" -N "" -C "clauntty-test"
        echo ""
        echo -e "Private key: ${YELLOW}$KEY_DIR/test_key${NC}"
        echo -e "Public key:  ${YELLOW}$KEY_DIR/test_key.pub${NC}"

        # Update authorized_keys if server is running
        if docker ps | grep -q "$CONTAINER_NAME"; then
            cp "$KEY_DIR/test_key.pub" "$KEY_DIR/authorized_keys"
            docker cp "$KEY_DIR/authorized_keys" "$CONTAINER_NAME:/home/testuser/.ssh/authorized_keys"
            docker exec "$CONTAINER_NAME" chown testuser:testuser /home/testuser/.ssh/authorized_keys
            docker exec "$CONTAINER_NAME" chmod 600 /home/testuser/.ssh/authorized_keys
            echo -e "${GREEN}Updated authorized_keys in running container${NC}"
        fi
        ;;

    test)
        echo -e "${GREEN}Testing SSH connection...${NC}"
        echo ""
        echo "Testing password auth:"
        echo "(You'll need to enter 'testpass' when prompted)"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" testuser@localhost echo "Password auth works!"

        if [ -f "$KEY_DIR/test_key" ]; then
            echo ""
            echo "Testing key auth:"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEY_DIR/test_key" -p "$SSH_PORT" testuser@localhost echo "Key auth works!"
        fi
        ;;

    logs)
        docker logs -f "$CONTAINER_NAME"
        ;;

    *)
        echo "Usage: $0 {start|stop|status|keygen|test|logs}"
        echo ""
        echo "Commands:"
        echo "  start   - Build and start the SSH test server"
        echo "  stop    - Stop the SSH test server"
        echo "  status  - Check if server is running"
        echo "  keygen  - Generate new SSH key pair"
        echo "  test    - Test SSH connection (password and key)"
        echo "  logs    - Show container logs"
        exit 1
        ;;
esac
