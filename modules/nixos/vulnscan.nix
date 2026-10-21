# Vulnerability scanning, Phase 6 Stage A.
#
# Inventory: which image every running container uses, on Aegis and Cerberus,
# with each container's exposure from security/exposure.nix. Aegis's images are
# also saved into a spool for the scanners. Refreshed daily and whenever a
# container starts on Aegis. Cerberus is read over SSH with a key that can do
# nothing but run the inventory command.
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
  ];

  sops.secrets.vulnscan_cerberus_ssh_key = {
    format = "yaml";
    sopsFile = ../../secrets/vulnscan.yaml;
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
        --format '{{.ID}}' |
        while read -r _; do
          # compose up starts containers in bursts; let it settle first
          while read -r -t 30 _; do :; done
          systemctl start vulnscan-inventory.service || true
        done
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
  };
}
