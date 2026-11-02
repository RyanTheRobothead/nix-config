# Hardening for internet-facing hosts: SSH only over the mesh, keys only,
# users and their passwords declared in the flake.
{ ... }:
{
  networking.firewall.enable = true;

  services.openssh = {
    enable = true;
    # Not on the public interface; tailscale0 opens it below. The Lish
    # console is the break-glass path.
    openFirewall = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      X11Forwarding = false;
    };
    # ed25519 only: it doubles as the sops identity
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

  users.mutableUsers = false;
  security.sudo.execWheelOnly = true;

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
  };
}
