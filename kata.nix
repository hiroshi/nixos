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

  # Applied by k3s's own in-cluster deploy controller (which runs with full
  # server privilege), not by any pod's kubectl -- RuntimeClass is a
  # cluster-scoped resource, so a namespace-scoped RoleBinding (like the
  # claude-code ServiceAccount's) could never be granted permission to
  # create it directly.
  services.k3s.manifests.kata-runtimeclass.source = ./k8s/kata/runtimeclass.yaml;
}
