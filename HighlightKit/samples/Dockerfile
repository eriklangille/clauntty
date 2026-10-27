# Test SSH server for Clauntty
FROM alpine:3.20

ARG USER=testuser
ENV LANG=C.UTF-8

RUN apk add --no-cache openssh git \
    && adduser -D "$USER" \
    && echo "${USER}:testpass" | chpasswd

COPY keys/test_key.pub /home/$USER/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
