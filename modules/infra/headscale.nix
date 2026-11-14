# Headscale on SleeperService: the tailnet's own control server, replacing
# Tailscale's, at hs.ryandlewis.dev behind nginx, with its embedded DERP relay.
#
# Until the one-evening cutover at the end of Phase 2 the existing devices
# stay on Tailscale's tailnet, and so does this host (it reaches Aegis that
# way), so Headscale starts with test devices only. A device is on one
# control server at a time.
#
# The Noise and DERP private keys are in secrets/sleeperservice/headscale.yaml,
# so a rebuild keeps the server's identity and registered devices don't have
# to log in again. Nodes and pre-auth keys live in the SQLite database, which
# needs this host's restic set (Backups).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "hs.ryandlewis.dev";
  # Gatus has 8080
  port = 8085;
  # Personal devices register under these; created at boot by headscale-users
  users = [ "luckierdodge" ];

  # Grants, not legacy ACLs (Headscale's docs recommend them). For now every
  # device of luckierdodge's reaches every other, and may use an exit node.
  # principals.nix generates this once agents and tags join (Identity).
  policy = {
    tagOwners = {
      "tag:server" = [ "luckierdodge@" ];
    };
    grants = [
      {
        src = [ "luckierdodge@" ];
        dst = [
          "luckierdodge@"
          "tag:server"
          "autogroup:internet"
        ];
        ip = [ "*" ];
      }
    ];
  };
in
{
  sops.secrets = lib.genAttrs [ "headscale_noise_key" "headscale_derp_key" ] (_: {
    sopsFile = ../../secrets/sleeperservice/headscale.yaml;
    owner = "headscale";
    restartUnits = [ "headscale.service" ];
  });

  services.headscale = {
    enable = true;
    inherit port;
    settings = {
      server_url = "https://${domain}";
      metrics_listen_addr = "127.0.0.1:9090";
      grpc_listen_addr = "127.0.0.1:50443";
      # nginx is in front: take the client's address from its headers
      trusted_proxies = [
        "127.0.0.1/32"
        "::1/128"
      ];
      noise.private_key_path = config.sops.secrets.headscale_noise_key.path;
      derp = {
        server = {
          enabled = true;
          # Unset, the NixOS config leaves these empty and the relay is
          # advertised as region 0, which Tailscale reads as "no region".
          # 900-999 are clear of Tailscale's own region IDs.
          region_id = 999;
          region_code = "sleeperservice";
          region_name = "SleeperService";
          private_key_path = config.sops.secrets.headscale_derp_key.path;
          # Both address families, since the relay advertises both
          stun_listen_addr = ":3478";
          # Linode's addresses, as in dns/dnsconfig.js; a new Linode changes both
          ipv4 = "172.234.194.242";
          ipv6 = "2600:3c06::2000:a7ff:fe63:bba7";
        };
        # Tailscale's public relays stay in the map beside ours: with only
        # one relay, this host going down would strand every relayed path
        urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
      };
      dns = {
        magic_dns = true;
        # Must differ from server_url's domain (Internal DNS)
        base_domain = "mesh.ryandlewis.dev";
        # Blocky on the Pis doesn't exist yet, so devices keep their own
        # resolvers and only gain MagicDNS names. Revisit at cutover.
        override_local_dns = false;
      };
      policy.path = pkgs.writeText "headscale-policy.json" (builtins.toJSON policy);
      # Nix pins the version
      disable_check_updates = true;
    };
  };

  # Users aren't declarative in Headscale; create any missing ones, so a
  # rebuild needs no manual step before devices can register
  systemd.services.headscale-users = {
    description = "Create Headscale users";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      config.services.headscale.package
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "headscale";
      Group = "headscale";
    };
    script = ''
      # The CLI talks to the server over its socket, which takes a moment
      existing=""
      for _ in $(seq 30); do
        existing=$(headscale users list -o json 2>/dev/null) && break
        sleep 1
      done
      if [ -z "$existing" ]; then
        echo "headscale isn't answering on its socket" >&2
        exit 1
      fi
      for u in ${lib.escapeShellArgs users}; do
        if ! jq -e --arg u "$u" 'any(.[]?; .name == $u)' <<<"$existing" >/dev/null; then
          headscale users create "$u"
        fi
      done
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    useACMEHost = "ryandlewis.dev";
    onlySSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      # The control protocol upgrades with POST and "Upgrade:
      # tailscale-control-protocol"; NixOS's upgrade map passes any value
      proxyWebsockets = true;
      # Map long-polls and DERP relays idle between keepalives every 50-59s
      # (hscontrol/poll.go), right at nginx's default 60s timeout
      extraConfig = ''
        proxy_buffering off;
        proxy_set_header True-Client-IP $remote_addr;
        proxy_read_timeout 10m;
        proxy_send_timeout 10m;
      '';
    };
  };
  # Plain HTTP: clients probe DERP servers for captive portals at
  # /generate_204, which must answer 204, not a redirect
  services.nginx.virtualHosts."${domain}-http" = {
    serverName = domain;
    locations."= /generate_204".return = "204";
    locations."/".return = "301 https://${domain}$request_uri";
  };

  # STUN for the embedded DERP relay
  networking.firewall.allowedUDPPorts = [ 3478 ];
}
