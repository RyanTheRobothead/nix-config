# Gatus on SleeperService: watches Aegis over the tailnet and the public
# names from outside, and alerts through ntfy on this host, so an Aegis
# outage still gets reported. Replaces the Gatus containers on Cerberus and
# Aegis; Aegis keeps one, watching this host, since ntfy goes down with it.
#
# The UI is on the tailnet only: http://sleeperservice:8080.
{ config, lib, ... }:
let
  check = group: name: url: conditions: {
    inherit
      group
      name
      url
      conditions
      ;
    interval = "60s";
    alerts = [ { type = "ntfy"; } ];
  };

  http =
    group: name: url:
    check group name url [ "[STATUS] == 200" ];

  # Services on Aegis, by MagicDNS name: published on its tailnet address
  # (dockerfiles #21), or native and trusted on tailscale0
  aegis = [
    (http "aegis" "syncthing" "http://aegis:8384")
    (http "aegis" "foundryvtt" "http://aegis:30000")
    (http "aegis" "neofoundryvtt" "http://aegis:30001")
    (http "aegis" "pihole-web" "http://aegis:8880/admin/")
    # Pi-hole itself answering, not some upstream: the old check asked 8.8.8.8
    (
      (check "aegis" "pihole-dns" "100.117.195.49" [ "[DNS_RCODE] == NOERROR" ])
      // {
        dns = {
          query-name = "example.com";
          query-type = "A";
        };
      }
    )
    (http "aegis" "scrutiny" "http://aegis:8888")
    (http "aegis" "paperless" "http://aegis:8000")
    (http "aegis" "plex" "http://aegis:32400/web/index.html")
    (http "aegis" "jellyfin" "http://aegis:8096")
    (http "aegis" "audiobookshelf" "http://aegis:13378")
    (http "aegis" "qbittorrent" "http://aegis:7070")
    (http "aegis" "sonarr" "http://aegis:8989")
    (http "aegis" "radarr" "http://aegis:7878")
    (http "aegis" "lidarr" "http://aegis:8686")
    # Answers 401 without credentials
    (check "aegis" "nzbget" "http://aegis:6789" [ "[STATUS] < 500" ])
    (http "aegis" "ombi" "http://aegis:3579")
    (http "aegis" "prowlarr" "http://aegis:9696")
    (http "aegis" "vaultwarden" "http://aegis:28080")
    (check "aegis" "nextcloud" "tcp://aegis:21443" [ "[CONNECTED] == true" ])
    (http "aegis" "collabora" "http://aegis:9980/hosting/discovery")
    (http "aegis" "immich" "http://aegis:2283")
    (check "aegis" "schedule-bot" "http://aegis:8095/health" [
      "[STATUS] == 200"
      "[BODY].ok == true"
    ])
  ];

  # What the internet sees: SWAG on Cerberus until Phase 2 moves each name
  # here. Each checks a health path and that its certificate has two weeks
  # left.
  public =
    lib.mapAttrsToList
      (
        name: path:
        check "public" name "https://${name}.ryandlewis.dev${path}" [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 336h"
        ]
      )
      {
        audiobookshelf = "/healthcheck";
        cloud = "/status.php";
        collabora = "/hosting/discovery";
        foundry = "/";
        immich = "/api/server/ping";
        jellyfin = "/health";
        neofoundry = "/";
        plex = "/identity";
        request = "/";
        warden = "/alive";
      };

  # Cerberus's side services, until it is decommissioned in Phase 2
  cerberus = [
    (http "cerberus" "smokeping" "http://cerberus:8888")
    (http "cerberus" "librespeed" "http://cerberus:8889")
    (check "cerberus" "swag-https" "tcp://cerberus:443" [ "[CONNECTED] == true" ])
  ];

  home = [ (http "home" "home-assistant" "http://homeassistant:8123") ];

  # This host's own public face. ntfy's down state can't alert through
  # itself; Aegis's Gatus watches it too and falls back to Discord.
  self = [
    (check "sleeperservice" "ntfy" "https://ntfy.ryandlewis.dev/v1/health" [
      "[STATUS] == 200"
      "[BODY].healthy == true"
      "[CERTIFICATE_EXPIRATION] > 336h"
    ])
    (http "sleeperservice" "nginx-test" "https://test.ryandlewis.dev/")
    (check "sleeperservice" "headscale" "https://hs.ryandlewis.dev/health" [
      "[STATUS] == 200"
      "[CERTIFICATE_EXPIRATION] > 336h"
    ])
  ];
in
{
  sops.secrets.ntfy_token_gatus.sopsFile = ../../secrets/sleeperservice/ntfy.yaml;
  sops.templates."gatus-env" = {
    content = ''
      NTFY_TOKEN=${config.sops.placeholder.ntfy_token_gatus}
    '';
    restartUnits = [ "gatus.service" ];
  };

  services.gatus = {
    enable = true;
    environmentFile = config.sops.templates."gatus-env".path;
    settings = {
      web.port = 8080;
      storage = {
        type = "sqlite";
        path = "/var/lib/gatus/data.db";
      };
      alerting.ntfy = {
        # Straight to ntfy on this host, so alerts don't depend on nginx,
        # the certificate or DNS
        url = "http://${config.services.ntfy-sh.settings.listen-http}";
        topic = "alerts";
        # Gatus expands environment variables in its config
        token = "\${NTFY_TOKEN}";
        priority = 4;
        default-alert = {
          failure-threshold = 3;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };
      endpoints = aegis ++ public ++ cerberus ++ home ++ self;
    };
  };

  # The UI over the tailnet only, like SSH (profiles/hardening.nix)
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.gatus.settings.web.port
  ];
}
