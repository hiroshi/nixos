# syntax=docker/dockerfile:1
FROM nixos/nix:latest AS builder

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src
COPY flake.nix ./
RUN nix flake lock --impure

ENV NIXPKGS_ALLOW_UNFREE=1
RUN nix build --impure \
    --option filter-syscalls false \
    '.#env' -o /result

# Copy the closure (dependency paths) as-is into /rootfs, and add symlinks
# at stable paths for easier execution.
RUN mkdir -p /rootfs/usr /rootfs/bin /rootfs/etc/ssl/certs && \
    nix-store -qR /result | xargs -I{} cp -a --parents {} /rootfs/ && \
    ln -s "$(readlink -f /result)/bin" /rootfs/usr/bin && \
    ln -s /usr/bin/bash /rootfs/bin/sh && \
    ln -s "$(readlink -f /result)/etc/ssl/certs/ca-bundle.crt" /rootfs/etc/ssl/certs/ca-bundle.crt

FROM scratch
COPY --from=builder /rootfs /
ENV SHELL=/usr/bin/bash
ENV HOME=/home/claude
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
ENV GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt

# scratch has no /etc/passwd, so create a non-root user (claude, uid/gid 1000)
# ourselves. Own HOME by that user since it's used as a PV mount point.
RUN mkdir -p /home/claude/workspace /tmp && \
    echo "claude:x:1000:1000:claude:/home/claude:/usr/bin/bash" > /etc/passwd && \
    echo "claude:x:1000:" > /etc/group && \
    chown -R 1000:1000 /home/claude && \
    chmod 1777 /tmp

# Rootless podman needs newuidmap/newgidmap to be setuid-root to create
# multi-uid user namespaces (NixOS normally wraps these via the podman
# module; we're bypassing that module here, so do it by hand), plus a
# subuid/subgid range delegated to claude and the usual /etc/containers
# config. driver=vfs avoids needing overlay/fuse-overlayfs privileges,
# at the cost of using more disk per layer.
RUN chown 0:0 /usr/bin/newuidmap /usr/bin/newgidmap && \
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap && \
    echo "claude:100000:65536" > /etc/subuid && \
    echo "claude:100000:65536" > /etc/subgid && \
    mkdir -p /etc/containers \
             /home/claude/.local/share/containers/storage \
             /tmp/containers/storage \
             /tmp/run-claude && \
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > /etc/containers/policy.json && \
    printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf && \
    printf '[storage]\ndriver = "vfs"\ngraphroot = "/home/claude/.local/share/containers/storage"\nrunroot = "/tmp/containers/storage"\n' > /etc/containers/storage.conf && \
    printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' > /etc/containers/containers.conf && \
    chown -R 1000:1000 /home/claude/.local /tmp/containers /tmp/run-claude

ENV XDG_RUNTIME_DIR=/tmp/run-claude

USER claude
WORKDIR /home/claude/workspace
ENTRYPOINT ["/usr/bin/claude"]
