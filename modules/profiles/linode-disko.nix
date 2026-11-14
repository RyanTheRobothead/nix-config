# A Linode's disk, partitioned by nixos-anywhere at install.
# Linode boots legacy BIOS, so GRUB needs a BIOS boot partition on the GPT
# disk. The config profile's kernel must be "Direct Disk", which boots this
# disk's own GRUB rather than Linode's (hosts/provision-linode.sh sets it).
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
