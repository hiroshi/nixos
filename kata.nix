# Kata Containers RuntimeClass for k3s: lets a pod opt in to running inside
# a real hardware VM (KVM/QEMU guest kernel) instead of sharing the host
# kernel via namespaces. This makes it safe to grant a pod strong privileges
# (CAP_SYS_ADMIN, privileged: true) -- e.g. so it can run a normal Docker
# daemon to build arbitrary Dockerfiles -- because the security boundary is
# the hypervisor, not Linux capabilities/namespaces.
#
# `boot.kernelModules = [ "kvm-intel" ]` is already set in
# hardware-configuration.nix (auto-detected on this bare-metal host); no
# need to repeat it here.
{ config, lib, pkgs, ... }:

let
  # Host-local path used purely as the direct-volume registry key -- it does
  # not need to exist as a real directory. Must match the `hostPath.path` in
  # k8s/claude-code/deployment.yaml's `docker-data` volume exactly, since
  # Kata's virtcontainers matches on this string, not the LV/device path.
  dockerDataDirectVolPath = "/var/lib/kata-directvol/claude-code-docker-data";

  # The shipped QEMU hypervisor config has `disable_block_device_use = true`
  # by default, which makes virtcontainers' checkBlockDeviceSupport() always
  # return false -- this silently skips Kata's direct-assigned-volume handling
  # entirely (container.go's mount loop just falls through to a normal
  # virtiofs bind-mount even when a mountInfo.json is registered via
  # `kata-runtime direct-volume add`). Confirmed by grepping the real shipped
  # file: ${pkgs.kata-runtime}/share/defaults/kata-containers/configuration-qemu.toml.
  #
  # `enable_debug = false` -> true (all 3 occurrences: [hypervisor.qemu],
  # [agent.kata], [runtime]) -- after a 2026-08-09 incident where the
  # claude-code pod's Kata sandbox died with the shim only logging "Dead
  # agent" / "CheckRequest timed out" (containerd-shim-v2 lost its vsock
  # ping to the in-guest kata-agent), with *no* corresponding entry in the
  # host's kernel log or systemd-oomd log -- i.e. something killed the
  # guest from *inside* the guest's own kernel, which the host has no
  # visibility into at all. Confirmed by reading kata-containers v3.29.0
  # source (the version this flake.lock's nixpkgs pin resolves to):
  # sandbox.go's startVM() only creates the console watcher that streams
  # the guest's console.sock line-by-line into the shim's own log (as
  # `msg="reading guest console"`) when HypervisorConfig.Debug is true
  # (i.e. [hypervisor.qemu] enable_debug); and that Debug()-level call is
  # filtered out entirely unless the runtime's own log level is also
  # raised, which config.go only does when [runtime] enable_debug is true
  # -- so both must be flipped together for the console stream to actually
  # reach the shim's log output ([agent.kata] enable_debug flipped too, for
  # the in-guest agent's own debug-level messages as a second signal).
  # With this, a future guest-side OOM-killer/panic would show up in the
  # same `kata[PID]:` journald source already used to diagnose this
  # incident, instead of leaving no trace at all.
  kataConfigQemu = pkgs.runCommand "configuration-qemu-directvol.toml" { } ''
    sed \
      -e 's/^disable_block_device_use.*/disable_block_device_use = false/' \
      -e 's/^enable_debug = false/enable_debug = true/' \
      ${pkgs.kata-runtime}/share/defaults/kata-containers/configuration-qemu.toml > $out
  '';

  # k3s reads this file as a Go template and exposes the built-in default
  # config as a "base" template, so we don't need to hand-copy k3s's whole
  # stock containerd config here -- just render it via `{{ template "base"
  # . }}` and append the kata runtime on top. This is k3s's own documented
  # mechanism for extending (not replacing) the default containerd config.
  configV3Tmpl = pkgs.writeText "config-v3.toml.tmpl" ''
    {{ template "base" . }}

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'kata']
      runtime_type = "io.containerd.kata.v2"
      # Without this, containerd tries to pass every host device into
      # privileged containers, which breaks (and defeats the point of) the
      # Kata VM boundary. Kata's own docs say this must be true.
      privileged_without_host_devices = true

      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'kata'.options]
        ConfigPath = "${kataConfigQemu}"
  '';
in
{
  systemd.services.k3s.serviceConfig.DeviceAllow = [
    "/dev/kvm rwm"
    "/dev/vhost-vsock rwm"
    "/dev/vhost-net rwm"
    "/dev/net/tun rwm"
    # Not kata-related: setting DeviceAllow at all switches this unit's
    # device cgroup from unrestricted to an allowlist, and kubelet itself
    # (independent of kata) needs to open /dev/kmsg. Omitting this broke
    # k3s entirely on first rollout (kubelet failed to start -> whole k3s
    # process shut down, apiserver included).
    "/dev/kmsg rwm"
  ];
  systemd.services.k3s.serviceConfig.Delegate = "yes";

  # Puts `containerd-shim-kata-v2` on k3s's PATH so containerd can exec it
  # for the "kata" runtime handler configured below.
  systemd.services.k3s.path = [ pkgs.kata-runtime ];

  systemd.tmpfiles.rules = [
    "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${configV3Tmpl}"
  ];

  # Gives claude-code's dockerd sidecar a real block-backed volume for
  # /var/lib/docker instead of the tmpfs emptyDir workaround (see
  # hiroshi/nixos#32) -- lets overlay2 work (virtiofs rejects it with
  # "invalid argument") without counting image layers/build cache against
  # the pod's memory cgroup the way tmpfs pages do.
  systemd.services.kata-docker-data-directvol-setup = {
    description = "Provision and register the Kata direct-assigned block volume for claude-code's docker-data";
    wantedBy = [ "multi-user.target" ];
    # Needs myvg1 to exist first (topolvm.nix creates it), and must run
    # before k3s starts creating containers, since virtcontainers only
    # honors a direct-volume mount if its registry entry already exists at
    # container-creation time.
    after = [ "topolvm-lvm-setup.service" ];
    before = [ "k3s.service" ];
    path = [ pkgs.lvm2 pkgs.e2fsprogs pkgs.kata-runtime ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # The LV + its filesystem are created once and persist across reboots;
    # only the direct-volume registration needs to be redone every boot,
    # since virtcontainers reads its registry from /run (tmpfs, cleared on
    # reboot).
    script = ''
      set -eu

      if ! lvs myvg1/claude-code-docker-data >/dev/null 2>&1; then
        # --yes / --wipesignatures y / -F: this VG has previously held other
        # LVs (e.g. the hiroshi/nixos#32 spike's throwaway test LV) that
        # were removed without zeroing -- lvremove doesn't erase data, so a
        # freshly created LV can land on reused extents still carrying a
        # stale filesystem signature. Both lvcreate and mkfs.ext4 would
        # otherwise prompt interactively to confirm overwriting it, which
        # hangs forever (defaults to "no") under a non-interactive systemd
        # unit. (An earlier attempt used the combined short flag `-Wy`,
        # which did not actually suppress the prompt -- spelling both
        # flags out explicitly here instead.)
        lvcreate --yes --wipesignatures y -L 20G -n claude-code-docker-data myvg1
        mkfs.ext4 -F /dev/myvg1/claude-code-docker-data
      else
        # Idempotently grow an already-created LV if the target size above
        # was increased since it was first created (e.g. 4G -> 20G) --
        # lvextend/resize2fs are no-ops if already at/above the target, same
        # pattern as topolvm.nix's truncate -s / pvresize.
        lvextend -L 20G /dev/myvg1/claude-code-docker-data || true
        # resize2fs refuses to run on an ext4 filesystem that was just grown
        # by lvextend without a forced check first ("Please run 'e2fsck -f'
        # first"). e2fsck -f exits 1 when it corrects (harmless, expected)
        # errors -- only treat exit codes >1 as real failures.
        e2fsck -f -y /dev/myvg1/claude-code-docker-data || [ $? -le 1 ]
        resize2fs /dev/myvg1/claude-code-docker-data
      fi

      kata-runtime direct-volume add \
        --volume-path '${dockerDataDirectVolPath}' \
        --mount-info '{"volume-type":"block","device":"/dev/myvg1/claude-code-docker-data","fstype":"ext4","metadata":{},"options":[]}'
    '';
  };

  # Applied by k3s's own in-cluster deploy controller (which runs with full
  # server privilege), not by any pod's kubectl -- RuntimeClass is a
  # cluster-scoped resource, so a namespace-scoped RoleBinding (like the
  # claude-code ServiceAccount's) could never be granted permission to
  # create it directly.
  services.k3s.manifests.kata-runtimeclass.source = ./k8s/kata/runtimeclass.yaml;
}
