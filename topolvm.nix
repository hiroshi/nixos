# TopoLVM support: provides a "topolvm-provisioner" StorageClass backed by
# an LVM volume group ("myvg1"), which itself is backed by a loopback file
# on the root filesystem (no spare disk partition is available on this
# dual-boot machine).
{ config, lib, pkgs, ... }:

{
  boot.kernelModules = [ "loop" ];

  # lvmd runs in a privileged container with hostPID and drives LVM via
  # `nsenter --target 1 --mount -- /sbin/lvm ...`, i.e. it expects an
  # absolute /sbin/lvm path on the host. NixOS has no /sbin, so provide one.
  systemd.tmpfiles.rules = [
    "d /sbin 0755 root root -"
    "L+ /sbin/lvm - - - - /run/current-system/sw/bin/lvm"
  ];

  systemd.services.topolvm-lvm-setup = {
    description = "Create loopback-backed LVM volume group for TopoLVM";
    wantedBy = [ "multi-user.target" ];
    before = [ "k3s.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.util-linux pkgs.lvm2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Runs on every boot: re-attaches the loop device (loop associations do
    # not survive a reboot), only creates the PV/VG the first time, and
    # grows the backing file + PV/VG idempotently if the target size below
    # was increased since the last boot (both `truncate -s` and `pvresize`
    # are no-ops if already at the target size).
    script = ''
      set -eu

      img=/var/lib/topolvm/pv-disk.img
      mkdir -p /var/lib/topolvm

      # Bumped 10G -> 50G: makes room for claude-code's dedicated
      # docker-data LV (see kata.nix) plus real headroom for future
      # multi-tenant PVCs, not just this one volume. Host root filesystem
      # has 117G total / ~82G free, and the NixOS system itself (OS + nix
      # store) doesn't need anywhere near that, so this leaves root with a
      # ~32G margin to grow.
      truncate -s 50G "$img"

      dev=$(losetup -j "$img" | cut -d: -f1)
      if [ -z "$dev" ]; then
        dev=$(losetup -f --show "$img")
      fi
      losetup -c "$dev"

      if ! vgs myvg1 >/dev/null 2>&1; then
        pvcreate -f "$dev"
        vgcreate myvg1 "$dev"
      else
        pvresize "$dev"
      fi
    '';
  };

  services.k3s.autoDeployCharts.topolvm = {
    repo = "https://topolvm.github.io/topolvm";
    name = "topolvm";
    version = "16.1.1";
    hash = "sha256-D1ddd+YSyHX5VrMPrRNV5WSwbnJSkAC4u9qzV8GLpQ4=";
    targetNamespace = "topolvm-system";
    createNamespace = true;
    values = {
      # Single-node cluster: no need for a redundant leader-election replica.
      controller.replicaCount = 1;
      lvmd.deviceClasses = [
        {
          name = "ssd";
          volume-group = "myvg1";
          default = true;
          # Safety margin reserved as unallocatable. Now that the VG is 50G
          # (bumped from the original 10G, see the loopback size above),
          # there's room for a more comfortable margin than the original
          # 1G chosen back when the whole VG was only 10G.
          spare-gb = 5;
        }
      ];
    };
  };
}
