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
RUN mkdir -p /rootfs/usr /rootfs/bin && \
    nix-store -qR /result | xargs -I{} cp -a --parents {} /rootfs/ && \
    ln -s "$(readlink -f /result)/bin" /rootfs/usr/bin && \
    ln -s /usr/bin/bash /rootfs/bin/sh

FROM scratch
COPY --from=builder /rootfs /
ENV SHELL=/usr/bin/bash
ENV HOME=/home/claude

# scratchベースで /etc/passwd が無いため、非rootユーザー(claude, uid/gid 1000)を
# 自前で用意する。HOME配下はPVマウント先として使うのでその所有者にしておく。
RUN mkdir -p /home/claude/workspace /tmp && \
    echo "claude:x:1000:1000:claude:/home/claude:/usr/bin/bash" > /etc/passwd && \
    echo "claude:x:1000:" > /etc/group && \
    chown -R 1000:1000 /home/claude && \
    chmod 1777 /tmp

USER claude
WORKDIR /home/claude/workspace
ENTRYPOINT ["/usr/bin/claude"]
