# Restic to Backblaze B2 for SleeperService: its own bucket and a key scoped
# to it without deleteFiles, so a compromised host can only hide history
# (the bucket deletes hidden files after 30 days). Same shape and names as
# Aegis's (nixos/aegis.nix), so restic-backblaze and docs/runbooks/restore.md
# work on both.
#
# What's here that a rebuild can't recreate: Headscale's nodes and pre-auth
# keys, Gatus's history, and the ACME account and certificate (re-issuable,
# but within Let's Encrypt's rate limits). Headscale's keys and ntfy's users
# are in sops and Nix already. Both databases are SQLite, copied with
# sqlite3 .backup into a staging directory, never backed up live.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  staging = "/var/lib/backup-staging";
  sqlite3 = lib.getExe pkgs.sqlite;
  # Gatus runs as a DynamicUser: /var/lib/gatus is a symlink, and restic
  # stores a symlink given as a path as the link alone
  databases = {
    headscale = config.services.headscale.settings.database.sqlite.path;
    gatus = "/var/lib/private/gatus/data.db";
  };
in
{
  sops.secrets =
    lib.genAttrs [ "restic_password" "restic_b2_account_id" "restic_b2_account_key" ]
      (_: {
        sopsFile = ../../secrets/sleeperservice/restic.yaml;
      });
  sops.templates."restic-env".content = ''
    B2_ACCOUNT_ID=${config.sops.placeholder.restic_b2_account_id}
    B2_ACCOUNT_KEY=${config.sops.placeholder.restic_b2_account_key}
  '';

  # For checking and putting back a restored database (restore.md)
  environment.systemPackages = [ pkgs.sqlite ];

  services.restic.backups.backblaze = {
    initialize = true;
    repository = "b2:ryan-the-robothead-sleeperservice-backup";
    paths = [
      staging
      "/var/lib/acme"
    ];
    backupPrepareCommand = ''
      set -eu
      install -d -m 700 ${staging}
      ${lib.concatStrings (
        lib.mapAttrsToList (name: db: ''
          ${sqlite3} ${db} ".backup ${staging}/${name}.sqlite"
        '') databases
      )}
    '';

    passwordFile = config.sops.secrets.restic_password.path;
    environmentFile = config.sops.templates."restic-env".path;

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--keep-yearly 2"
    ];
    checkOpts = [ "--with-cache" ];
  };

  # A sample of the data itself, weekly, as on Aegis
  systemd.services.restic-check-backblaze = {
    description = "Verify a sample of restic backup data on Backblaze B2";
    environment = removeAttrs config.systemd.services.restic-backups-backblaze.environment [ "PATH" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe config.services.restic.backups.backblaze.package} check --read-data-subset=5% --retry-lock 2h";
      EnvironmentFile = config.sops.templates."restic-env".path;
      CacheDirectory = "restic-backups-backblaze";
      CacheDirectoryMode = "0700";
      PrivateTmp = true;
    };
  };
  systemd.timers.restic-check-backblaze = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # A failed backup or check posts to ntfy here, with Gatus's token (it
  # can only write to alerts). Nothing else would notice.
  systemd.services.restic-backups-backblaze.onFailure = [ "notify-failure@%n.service" ];
  systemd.services.restic-check-backblaze.onFailure = [ "notify-failure@%n.service" ];
  systemd.services."notify-failure@" = {
    description = "Post that %i failed to ntfy";
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.sops.templates."gatus-env".path;
    };
    scriptArgs = "%i";
    script = ''
      ${lib.getExe pkgs.curl} -fsS \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $1 failed on ${config.networking.hostName}" \
        -H "Priority: 4" -H "Tags: warning" \
        -d "See journalctl -u $1." \
        http://${config.services.ntfy-sh.settings.listen-http}/alerts
    '';
  };
}
