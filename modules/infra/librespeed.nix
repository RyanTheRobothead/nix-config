# LibreSpeed on SleeperService, replacing the linuxserver container on
# Cerberus (Phase 2, batch 1): a speed test from home to the datacenter.
#
# The tailnet only, on the port it had on Cerberus:
# http://sleeperservice:8889. librespeed-rust serves the page itself rather
# than through nginx, since a proxy skews the measured speeds. Cerberus's
# PHP version kept results behind a stats password; with no one else on the
# tailnet, this one keeps none.
{ config, ... }:
{
  services.librespeed = {
    enable = true;
    frontend = {
      enable = true;
      pageTitle = "SleeperService speed test";
      contactEmail = "public@ryandlewis.dev";
      settings.telemetry_level = "off";
    };
    settings.listen_port = 8889;
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.librespeed.settings.listen_port
  ];
}
