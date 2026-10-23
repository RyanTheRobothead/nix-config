# Which containers each host exposes, for ranking vulnerability findings
# (Phase 6 Stage A). Plain data: modules/nixos/vulnscan.nix serialises it to
# /etc/vulnscan/exposure.json for the scanners.
#
# A container is public if it is listed here, or if its host is internet-facing
# and it publishes a port on every interface. Otherwise it is local when it
# publishes no ports from a network namespace of its own, and tailnet (reachable
# from the LAN or tailnet, not the internet) when it does. Later this is
# generated from the service attrset in Internal DNS and naming.
{
  aegis = {
    # Behind home NAT: public means whatever SWAG on Cerberus proxies to
    internetFacing = false;
    public = [
      "audiobookshelf"
      "collabora"
      "foundryvtt"
      "immich_server"
      "jellyfin"
      "neofoundryvtt"
      "nextcloud"
      # Published through gluetun's network namespace
      "ombi"
      "plex"
      "vaultwarden"
    ];
  };

  cerberus = {
    internetFacing = true;
    public = [ "swag" ];
  };
}
