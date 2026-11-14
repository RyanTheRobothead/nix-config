# SleeperService: the Linode VPS replacing Cerberus. It installs with
# nixos-anywhere and comes up on the tailnet. It runs public ingress, ntfy,
# Gatus and Headscale (test devices only until the Phase 2 cutover).
{ ... }:
{
  imports = [
    ../../modules/profiles/linode.nix
    ../../modules/profiles/server.nix
    ../../modules/profiles/hardening.nix
    ../../modules/infra/ingress.nix
    ../../modules/infra/ntfy.nix
    ../../modules/infra/gatus.nix
    ../../modules/infra/headscale.nix
  ];

  networking.hostName = "sleeperservice";

  # comin will evaluate the flake here (about 1.5 GB for Aegis's config)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 2048;
    }
  ];

  sops.secrets.tailscale_authkey.sopsFile = ../../secrets/sleeperservice/host.yaml;
  sops.secrets.luckierdodge_password_hash = {
    sopsFile = ../../secrets/sleeperservice/host.yaml;
    neededForUsers = true;
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "26.05";
}
