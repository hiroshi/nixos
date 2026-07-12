# syntax=docker/dockerfile:1
FROM nixos/nix:latest AS builder

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
# RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf && \
#     echo "sandbox = false" >> /etc/nix/nix.conf


WORKDIR /src
COPY flake.nix ./
RUN nix flake lock --impure

ENV NIXPKGS_ALLOW_UNFREE=1
# RUN --mount=type=cache,target=/nix,id=nix-store \
#     nix build --impure '.#docker' -o /result
# RUN nix build --impure '.#docker' -o /result
# RUN nix build --impure --option sandbox false '.#docker' -o /result
RUN nix build --impure \
    --option filter-syscalls false \
    '.#docker' -o /result

RUN mkdir /rootfs && \
    nix-store -qR /result | xargs -I{} cp -a --parents {} /rootfs/

FROM scratch
COPY --from=builder /rootfs /
COPY --from=builder /result/bin/claude /usr/bin/claude
ENTRYPOINT ["/usr/bin/claude"]
