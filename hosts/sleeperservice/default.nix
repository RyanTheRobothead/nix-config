# SleeperService: the Linode VPS replacing Cerberus. Ingress, Headscale and
# external monitoring land here in later steps of Phase 1; this is the base
# that installs with nixos-anywhere and comes up on the tailnet.
{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    ./disko.nix
    ../../modules/profiles/server.nix
    ../../modules/profiles/hardening.nix
  ];

  networking.hostName = "sleeperservice";

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];
  boot.loader.grub = {
    enable = true;
    # disko installs GRUB to /dev/sda through its EF02 partition
    # Lish is a serial console
    extraConfig = ''
      serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1
      terminal_input serial
      terminal_output serial
    '';
  };
  boot.loader.timeout = 10;
  boot.kernelParams = [ "console=ttyS0,19200n8" ];

  # Linode's guide: eth0, DHCP for IPv4, SLAAC for IPv6
  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;

  # comin will evaluate the flake here (about 1.5 GB for Aegis's config)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 2048;
    }
  ];

  # Ingress (nginx, Phase 1 step 2)
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  sops.secrets.tailscale_authkey.sopsFile = ../../secrets/sleeperservice/host.yaml;
  sops.secrets.luckierdodge_password_hash = {
    sopsFile = ../../secrets/sleeperservice/host.yaml;
    neededForUsers = true;
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "26.05";
}
