# Smokeping on SleeperService, replacing the linuxserver container on
# Cerberus (Phase 2, batch 1): latency from a datacenter vantage point to
# home, a few public sites and the big DNS resolvers.
#
# The UI is on the tailnet only: http://sleeperservice:8888, the port it had
# on Cerberus. The module's nginx vhost would otherwise listen on :80, the
# public ingress port.
#
# Target names match Cerberus's, so its RRDs (/var/lib/smokeping/data) carry
# over as is: the Database section is the module default, which is what
# Cerberus used, and Smokeping won't open RRDs made with a different step or
# ping count. Cerberus also pinged foundry, plex, jellyfin and cloud by their
# public names, which only ever reached its own SWAG (and would reach this
# host after the cutover), so home is measured over the tailnet instead.
{ config, pkgs, ... }:
let
  port = 8888;

  target = name: title: host: ''
    ++ ${name}
    menu = ${title}
    title = ${title}
    host = ${host}
  '';

  resolvers = ''
    ${target "GoogleDNS1" "Google DNS 8.8.8.8" "8.8.8.8"}
    ${target "GoogleDNS2" "Google DNS 8.8.4.4" "8.8.4.4"}
    ${target "OpenDNS1" "OpenDNS 208.67.222.222" "208.67.222.222"}
    ${target "OpenDNS2" "OpenDNS 208.67.220.220" "208.67.220.220"}
    ${target "CloudflareDNS1" "Cloudflare DNS 1.1.1.1" "1.1.1.1"}
    ${target "CloudflareDNS2" "Cloudflare DNS 1.0.0.1" "1.0.0.1"}
    ${target "L3-1" "Level3 DNS 4.2.2.1" "4.2.2.1"}
    ${target "L3-2" "Level3 DNS 4.2.2.2" "4.2.2.2"}
    ${target "Quad9" "Quad9 DNS 9.9.9.9" "9.9.9.9"}
  '';
in
{
  services.smokeping = {
    enable = true;
    # The default is networking.fqdn, which this host doesn't set
    hostName = "sleeperservice";
    cgiUrl = "http://sleeperservice:${toString port}/smokeping.fcgi";
    owner = "Ryan Lewis";

    probeConfig = ''
      + FPing
      binary = ${config.security.wrapperDir}/fping

      + DNS
      binary = ${pkgs.dig}/bin/dig
      lookup = google.com
      pings = 5
      step = 300
    '';

    targetConfig = ''
      probe = FPing
      menu = Top
      title = Network Latency Grapher
      remark = Latency from SleeperService, on Linode.

      + MyStuff
      menu = My Stuff
      title = My Stuff

      ${target "Website" "ryandlewis.dev" "ryandlewis.dev"}
      ${target "Aegis" "Aegis (tailnet)" "aegis"}
      ${target "HomeAssistant" "Home Assistant (tailnet)" "homeassistant"}

      + NolansStuff
      menu = Nolan's Stuff
      title = Nolan's Stuff

      ${target "Factorio" "Factorio" "factorio.barrelmaker.dev"}

      + InternetSites
      menu = The Internet
      title = The Internet

      ${target "Youtube" "YouTube" "youtube.com"}
      ${target "JupiterBroadcasting" "JupiterBroadcasting" "jupiterbroadcasting.com"}
      ${target "GoogleSearch" "google.com" "google.com"}
      ${target "linuxserverio" "linuxserver.io" "linuxserver.io"}

      + DNS
      menu = DNS
      title = DNS

      ${resolvers}

      + DNSProbes
      menu = DNS Probes
      title = DNS Probes
      probe = DNS

      ${resolvers}
    '';
  };

  services.nginx.virtualHosts.smokeping.listen = [
    {
      addr = "0.0.0.0";
      inherit port;
    }
    {
      addr = "[::]";
      inherit port;
    }
  ];

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ port ];
}
