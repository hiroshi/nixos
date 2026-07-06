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
      lvmd.deviceClasses = [
        {
          name = "ssd";
          volume-group = "myvg1";
          default = true;
          # The chart's default spare-gb (10) is a safety margin reserved as
          # unallocatable; our VG is only 10G total, so that default would
          # leave zero usable capacity. Keep a smaller margin instead.
          spare-gb = 1;
        }
      ];
      # Redeclare the whole entry (Helm/nix lists replace rather than merge)
      # so we keep the chart's other sane defaults while adding isDefaultClass.
      storageClasses = [
        {
          name = "topolvm-provisioner";
          storageClass = {
            fsType = "xfs";
            volumeBindingMode = "WaitForFirstConsumer";
            allowVolumeExpansion = true;
            isDefaultClass = true;
          };
        }
      ];
    };
  };

  # k3s's built-in "local-path" StorageClass is also marked as the default,
  # which would make PVCs without an explicit storageClassName ambiguous.
  # k3s reconciles that addon (and re-adds its "is-default-class: true"
  # annotation) every time k3s.service (re)starts, so a one-off `kubectl
  # patch` would not survive the next `nixos-rebuild switch`. Re-apply the
  # patch every time k3s starts instead.
  systemd.services.topolvm-unset-local-path-default = {
    description = "Unset default-StorageClass flag on k3s's local-path so topolvm-provisioner is the sole default";
    after = [ "k3s.service" ];
    partOf = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.k3s.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      for i in $(seq 1 60); do
        if k3s kubectl get storageclass local-path >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      k3s kubectl patch storageclass local-path \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    '';
  };
}
