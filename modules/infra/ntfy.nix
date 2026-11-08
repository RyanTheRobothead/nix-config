# ntfy on SleeperService: push notifications to phones, replacing Discord.
# Public at ntfy.ryandlewis.dev so alerts still arrive when the tailnet is
# what's broken, and closed to anyone without a login or token: every topic
# is deny-all unless granted below.
#
# Who may do what is declared here, not in ntfy's database. Passwords and
# tokens live in secrets/sleeperservice/ntfy.yaml; senders get write-only
# tokens to their topics, luckierdodge a login (for the apps) that reads all.
{ config, ... }:
let
  # Topics, by urgency: alerts (something is down), security (vulnscan
  # pages), updates (Renovate), digest (weekly summaries)
  access = [
    "luckierdodge:*:rw"
    "gatus:alerts:wo"
    "aegis:alerts:wo"
    "aegis:security:wo"
    "aegis:updates:wo"
    "aegis:digest:wo"
  ];
in
{
  sops.secrets =
    builtins.mapAttrs
      (_: _: {
        sopsFile = ../../secrets/sleeperservice/ntfy.yaml;
      })
      {
        ntfy_luckierdodge_hash = { };
        ntfy_sender_hash = { };
        ntfy_token_gatus = { };
        ntfy_token_aegis = { };
      };

  # Single-quoted: bcrypt hashes are full of $, which systemd would expand.
  # A changed user, grant or token restarts ntfy.
  sops.templates."ntfy-env".restartUnits = [ "ntfy-sh.service" ];
  sops.templates."ntfy-env".content = ''
    NTFY_AUTH_USERS='luckierdodge:${config.sops.placeholder.ntfy_luckierdodge_hash}:user,gatus:${config.sops.placeholder.ntfy_sender_hash}:user,aegis:${config.sops.placeholder.ntfy_sender_hash}:user'
    NTFY_AUTH_ACCESS='${builtins.concatStringsSep "," access}'
    NTFY_AUTH_TOKENS='gatus:${config.sops.placeholder.ntfy_token_gatus}:gatus,aegis:${config.sops.placeholder.ntfy_token_aegis}:aegis'
  '';

  services.ntfy-sh = {
    enable = true;
    environmentFile = config.sops.templates."ntfy-env".path;
    settings = {
      base-url = "https://ntfy.ryandlewis.dev";
      # nginx in front: rate-limit by the client's address, not nginx's
      behind-proxy = true;
      auth-default-access = "deny-all";
      enable-login = true;
      require-login = true;
      # iOS can only be woken through Apple, via ntfy.sh; only a message ID
      # goes there, and the phone fetches the message from here
      upstream-base-url = "https://ntfy.sh";
    };
  };
  services.nginx.virtualHosts."ntfy.ryandlewis.dev" = {
    useACMEHost = "ryandlewis.dev";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${config.services.ntfy-sh.settings.listen-http}";
      proxyWebsockets = true;
      # Subscriptions are long-lived streams: pass them through as they come,
      # and let them idle past nginx's default 60s
      extraConfig = ''
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3m;
        proxy_send_timeout 3m;
        client_max_body_size 1m;
      '';
    };
  };
}
