# Vulnerability scanning, Phase 6 Stage A.
#
# Inventory: which image every running container uses, on Aegis and Cerberus,
# with each container's exposure from security/exposure.nix. Aegis's images are
# also saved into a spool for the scanners. Refreshed daily and whenever a
# container starts on Aegis. Cerberus is read over SSH with a key that can do
# nothing but run the inventory command.
#
# Scan: Syft SBOMs each new digest (Aegis's from the spool, Cerberus's from
# its registry) and sbomnix the system when it changes; Grype rescans every
# SBOM every 6 hours. Results land in report/report.json and a textfile
# metric. New known-exploited findings on public services page Discord at
# once; the daily summary lists those and public Criticals, then anything else
# new; and any vulnscan unit failing says so there too.
#
# Trust: every CA bundle Syft finds in an image, and the host's, is checked
# against security/ca-denylist.toml along with the runtimes that carry their
# own roots; security/fix-watch.toml says when a fix lands for something that
# had none. Both report through the same scan.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Every running container and its image's registry digests, as JSON arrays,
  # never the container's environment. Cerberus's authorized_keys forces this
  # same string, so it holds no double quotes (Go raw strings use backticks).
  inventoryCommand = lib.concatStringsSep "; " [
    (
      "docker ps -q --no-trunc | xargs -r docker inspect --format "
      + "'[{{json .Name}},{{json .Config.Image}},{{json .Image}},{{json .HostConfig.NetworkMode}},"
      + "{{json .NetworkSettings.Ports}},{{json (index .Config.Labels `com.docker.compose.service`)}}]'"
    )
    (
      "docker ps -q --no-trunc | xargs -r docker inspect --format '{{.Image}}' | sort -u"
      + " | xargs -r docker image inspect --format '[{{json .Id}},{{json .RepoDigests}}]'"
    )
  ];

  inventory = pkgs.writeShellApplication {
    name = "vulnscan-inventory";
    runtimeInputs = with pkgs; [
      config.virtualisation.docker.package
      jq
      openssh
      coreutils
      findutils
      gnugrep
    ];
    text = ''
      # The backticks are Go template raw strings, not command substitution
      # shellcheck disable=SC2016
      INVENTORY_CMD=${lib.escapeShellArg inventoryCommand}
    ''
    + builtins.readFile ./vulnscan-inventory.sh;
  };

  scanner = pkgs.writers.writePython3Bin "vulnscan-scan" {
    # Line length is left to the formatter's judgement
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./vulnscan-scan.py);

  # Syft captures these files' contents with each SBOM, for the trust check
  syftConfig = pkgs.writeText "vulnscan-syft.json" (
    builtins.toJSON {
      file.content = {
        globs = [
          "**/ca-certificates.crt"
          "**/ca-bundle.crt"
          "**/tls-ca-bundle.pem"
          "**/cert.pem"
          "**/cacert.pem"
        ];
        skip-files-above-size = 4194304;
      };
    }
  );

  # Shared by the scan, summary and failure units
  scanEnvironment = {
    VULNSCAN_HOST = "aegis";
    VULNSCAN_KEV_FIXTURE = "${../../security/testdata/log4j-kev.cdx.json}";
    VULNSCAN_TRUST_FIXTURE = "${../../security/testdata/emsign-g3.pem}";
    VULNSCAN_SYFT_CONFIG = "${syftConfig}";
    VULNSCAN_CA_DENYLIST = "${../../security/ca-denylist.toml}";
    VULNSCAN_FIX_WATCH = "${../../security/fix-watch.toml}";
    VULNSCAN_WEBHOOK_FILE = "%d/discord-webhook";
    GRYPE_DB_CACHE_DIR = "/var/cache/vulnscan/grype";
    # Syft unpacks whole images here; immich's are several GB
    TMPDIR = "/var/cache/vulnscan/tmp";
  };

  scanHardening = {
    User = "vulnscan";
    Group = "vulnscan";
    LoadCredential = "discord-webhook:${config.sops.secrets.vulnscan_discord_webhook.path}";
    CapabilityBoundingSet = [ "" ];
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ReadWritePaths = [
      "/var/lib/vulnscan"
      "/var/cache/vulnscan"
    ];
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      # The nix daemon, for sbomnix
      "AF_UNIX"
    ];
    SystemCallArchitectures = "native";
    UMask = "0027";
  };

  # Aegis's tailnet addresses, the only place the Cerberus key is accepted from
  aegisTailnet = "100.117.195.49,fd7a:115c:a1e0::b537:c331";
  cerberusKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfi/JK1Lq3YIqUaCJ85LjzMC5oIgDiriyBf+QwTyiGD vulnscan@aegis";
in
{
  assertions = [
    {
      assertion = !lib.hasInfix "\"" inventoryCommand;
      message = "vulnscan: the inventory command must not contain double quotes; it is embedded in authorized_keys";
    }
  ];

  users.users.vulnscan = {
    isSystemUser = true;
    group = "vulnscan";
  };
  users.groups.vulnscan = { };
  # Read the reports and inventories without sudo
  users.users.luckierdodge.extraGroups = [ "vulnscan" ];

  environment.systemPackages = [ inventory ];
  environment.etc."vulnscan/exposure.json".text = builtins.toJSON (
    import ../../security/exposure.nix
  );
  # The line for luckierdodge's authorized_keys on Cerberus
  environment.etc."vulnscan/cerberus-authorized-key".text = ''
    restrict,from="${aegisTailnet}",command="${inventoryCommand}" ${cerberusKey}
  '';

  # The root unit and the vulnscan units share these, so systemd's
  # StateDirectory, which would chown them to each unit's user, isn't used.
  # Whatever root writes into is root's: the scanners parse untrusted images,
  # and a compromised vulnscan must not be able to plant a symlink root then
  # writes through. vulnscan reads everything and writes only its own files
  # in inventory/, which is sticky so it can't replace root's.
  systemd.tmpfiles.rules = [
    "d /var/lib/vulnscan 0750 root vulnscan -"
    "d /var/lib/vulnscan/inventory 1770 root vulnscan -"
    # Outside restic's paths: the images are re-saved from Docker if lost
    "d /var/cache/vulnscan 0750 root vulnscan -"
    "d /var/cache/vulnscan/images 0750 root vulnscan -"
    # The scanners' own: root never writes here
    "d /var/lib/vulnscan/sbom 0750 vulnscan vulnscan -"
    "d /var/lib/vulnscan/results 0750 vulnscan vulnscan -"
    "d /var/lib/vulnscan/report 0750 vulnscan vulnscan -"
    "d /var/lib/vulnscan/metrics 0750 vulnscan vulnscan -"
    "d /var/cache/vulnscan/grype 0750 vulnscan vulnscan -"
    "d /var/cache/vulnscan/tmp 0750 vulnscan vulnscan -"
  ];

  sops.secrets.vulnscan_cerberus_ssh_key = {
    format = "yaml";
    sopsFile = ../../secrets/vulnscan.yaml;
  };
  # Gatus's alert webhook, shared
  sops.secrets.vulnscan_discord_webhook = {
    format = "yaml";
    sopsFile = ../../secrets/vulnscan-discord.yaml;
  };

  programs.ssh.knownHosts.cerberus = {
    hostNames = [
      "cerberus"
      "100.93.94.128"
    ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH3x2Ln29SrUJIKTEkMG2A3G6H3RANJhXjIv0awW0J4X";
  };

  # Root, for the Docker socket; the scanners themselves never touch it
  systemd.services.vulnscan-inventory = {
    description = "Inventory Aegis's container images for vulnerability scanning";
    onFailure = [ "vulnscan-notify-failure@%n.service" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    startAt = "daily";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe inventory} aegis";
      # docker save writes tens of GB on the first run
      Nice = 19;
      IOSchedulingClass = "idle";
      PrivateTmp = true;
      ProtectHome = true;
    };
  };

  systemd.services.vulnscan-inventory-cerberus = {
    description = "Inventory Cerberus's container images for vulnerability scanning";
    onFailure = [ "vulnscan-notify-failure@%n.service" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    startAt = "daily";
    environment.VULNSCAN_SSH_KEY = "%d/ssh-key";
    serviceConfig = {
      Type = "oneshot";
      User = "vulnscan";
      Group = "vulnscan";
      LoadCredential = "ssh-key:${config.sops.secrets.vulnscan_cerberus_ssh_key.path}";
      ExecStart = "${lib.getExe inventory} cerberus luckierdodge@cerberus";

      # Hardening
      CapabilityBoundingSet = [ "" ];
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/vulnscan" ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
    };
  };

  systemd.timers.vulnscan-inventory.timerConfig.Persistent = true;
  systemd.timers.vulnscan-inventory-cerberus.timerConfig.Persistent = true;

  systemd.services.vulnscan-scan = {
    description = "SBOM and rescan every image in use for vulnerabilities";
    onFailure = [ "vulnscan-notify-failure@%n.service" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startAt = "*-*-* 00/6:00:00";
    path = [
      pkgs.syft
      pkgs.grype
      pkgs.sbomnix
      config.nix.package
    ];
    environment = scanEnvironment;
    serviceConfig = scanHardening // {
      Type = "oneshot";
      ExecStart = "${lib.getExe scanner} scan";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
  systemd.timers.vulnscan-scan.timerConfig.Persistent = true;

  # New inventories mean new digests to SBOM. A switch replaces the
  # /run/current-system symlink, which PathChanged doesn't see, so a new
  # system's SBOM waits for the 6-hourly timer.
  systemd.paths.vulnscan-scan = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "/var/lib/vulnscan/inventory";
  };

  systemd.services.vulnscan-summary = {
    description = "Post the daily vulnerability summary";
    onFailure = [ "vulnscan-notify-failure@%n.service" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startAt = "*-*-* 08:00:00";
    environment = scanEnvironment;
    serviceConfig = scanHardening // {
      Type = "oneshot";
      ExecStart = "${lib.getExe scanner} summary";
    };
  };
  systemd.timers.vulnscan-summary.timerConfig.Persistent = true;

  systemd.services."vulnscan-notify-failure@" = {
    description = "Report that %i failed";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = scanEnvironment;
    serviceConfig = scanHardening // {
      Type = "oneshot";
      ExecStart = "${lib.getExe scanner} notify-failure %i";
    };
  };

  # Compose deploys aren't switches, so watch for containers starting instead.
  # Inventory once at startup to catch anything started while this was down.
  systemd.services.vulnscan-inventory-watch = {
    description = "Re-inventory Aegis's images when a container starts";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    path = [ config.virtualisation.docker.package ];
    script = ''
      systemctl start vulnscan-inventory.service || true
      docker events --filter type=container --filter event=start \
        --format '{{.Action}}' |
        while read -r _; do
          # compose up starts containers in bursts; let it settle first
          while read -r -t 30 _; do :; done
          systemctl start vulnscan-inventory.service || true
        done
    '';
    serviceConfig = {
      Restart = "always";
      # Each start runs an inventory, so a watcher that keeps dying must not
      # restart every 10 seconds forever: back off to an hour
      RestartSec = 10;
      RestartSteps = 8;
      RestartMaxDelaySec = "1h";
    };
  };
}
