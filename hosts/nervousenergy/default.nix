# NervousEnergy: a throwaway Linode for rehearsing just provision. The
# Linode bits are SleeperService's, but nothing else is: no secrets, no
# tailnet, no services. Root SSH with Aegis's key on the public
# address is how the provisioning script checks it booted. Delete the Linode
# after each rehearsal.
{ ... }:
{
  imports = [ ../../modules/profiles/linode.nix ];

  networking.hostName = "nervousenergy";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    # Aegis, which runs just provision
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDBFLkyh44j2qa08ujLsr7PDNP409JI73VyFsntsfims ryan@ryandlewis.dev (aegis)"
  ];

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "26.05";
}
