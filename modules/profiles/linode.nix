# A Linode VPS: KVM guest, legacy BIOS boot from its own GRUB, the Lish
# serial console, and Linode's network setup. Installed with nixos-anywhere
# by just provision (hosts/provision-linode.sh).
{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    ./linode-disko.nix
  ];

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
  # One stable IPv6 address (the one in DNS), no rotating privacy addresses
  networking.tempAddresses = "disabled";
}
