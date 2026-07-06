# TopoLVM support: provides a "topolvm-provisioner" StorageClass backed by
# an LVM volume group ("myvg1"), which itself is backed by a loopback file
# on the root filesystem (no spare disk partition is available on this
# dual-boot machine).
{ config, lib, pkgs, ... }:

{
  boot.kernelModules = [ "loop" ];

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
    # not survive a reboot) and only creates the PV/VG the first time.
    script = ''
      set -eu

      img=/var/lib/topolvm/pv-disk.img
      mkdir -p /var/lib/topolvm

      if [ ! -f "$img" ]; then
        truncate -s 10G "$img"
      fi

      dev=$(losetup -j "$img" | cut -d: -f1)
      if [ -z "$dev" ]; then
        dev=$(losetup -f --show "$img")
      fi

      if ! vgs myvg1 >/dev/null 2>&1; then
        pvcreate -f "$dev"
        vgcreate myvg1 "$dev"
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
    };
  };
}
