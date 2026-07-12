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

# closure(依存パス一覧)をそのまま /rootfs にコピーし、
# 実行しやすいよう安定したパスへシンボリックリンクを張っておく
RUN mkdir -p /rootfs/usr/bin /rootfs/bin && \
    nix-store -qR /result | xargs -I{} cp -a --parents {} /rootfs/ && \
    ln -s "$(readlink -f /result)/bin/claude" /rootfs/usr/bin/claude && \
    ln -s "$(readlink -f /result)/bin/bash"   /rootfs/usr/bin/bash && \
    ln -s "$(readlink -f /result)/bin/bash"   /rootfs/bin/sh

FROM scratch
COPY --from=builder /rootfs /
ENV SHELL=/usr/bin/bash
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/claude"]
