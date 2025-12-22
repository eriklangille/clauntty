# SSH Test Server for Clauntty
# Provides both password and SSH key authentication for testing

FROM alpine:latest

# Install OpenSSH server
RUN apk add --no-cache openssh bash

# Create test user with password "testpass"
RUN adduser -D -s /bin/bash testuser && \
    echo "testuser:testpass" | chpasswd

# Configure SSH
RUN ssh-keygen -A && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    echo "AllowUsers testuser" >> /etc/ssh/sshd_config

# Create .ssh directory for key auth
RUN mkdir -p /home/testuser/.ssh && \
    chmod 700 /home/testuser/.ssh && \
    chown testuser:testuser /home/testuser/.ssh

# Copy authorized_keys if provided (will be mounted at runtime)
# The key will be added via volume mount

# Create a welcome message
RUN echo 'echo "Welcome to Clauntty SSH Test Server!"' >> /home/testuser/.bashrc && \
    echo 'echo "User: testuser | Password: testpass"' >> /home/testuser/.bashrc

EXPOSE 22

# Start SSH daemon
CMD ["/usr/sbin/sshd", "-D", "-e"]
