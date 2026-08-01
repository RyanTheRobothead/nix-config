# Audiobook CD ripper.
#
# Provides the `ripbook` command: walks you through a multi-disc audiobook one
# disc at a time, then merges the whole thing into a single chaptered .m4b laid
# out the way Audiobookshelf expects.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.audiobookRipper;

  ripbook = pkgs.writeShellApplication {
    name = "ripbook";
    runtimeInputs = with pkgs; [
      cdparanoia # error-corrected CD audio extraction
      ffmpeg # encoding, chapter metadata, duration probing
      curl # MusicBrainz lookups
      jq # state file + MusicBrainz JSON
      python3 # MusicBrainz disc ID (SHA-1 over the TOC)
      util-linux # eject
      coreutils
      findutils
      gnugrep
      gnused
      gawk
    ];
    text = ''
      RIPBOOK_LIBRARY_DEFAULT=${lib.escapeShellArg cfg.libraryPath}
      RIPBOOK_WORK_DEFAULT=${lib.escapeShellArg cfg.workDir}
      RIPBOOK_DEVICE_DEFAULT=${lib.escapeShellArg cfg.device}
      RIPBOOK_BITRATE_DEFAULT=${lib.escapeShellArg cfg.bitrate}
      RIPBOOK_CHANNELS_DEFAULT=${if cfg.stereo then "2" else "1"}
      RIPBOOK_CONTACT_DEFAULT=${lib.escapeShellArg cfg.contact}
    ''
    + builtins.readFile ./ripbook.sh;
  };
in
{
  options.services.audiobookRipper = {
    enable = lib.mkEnableOption "the ripbook audiobook CD ripper";

    libraryPath = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/aegis-storage/media-storage/audiobooks";
      description = ''
        Root of the Audiobookshelf book library. Finished books are written to
        {file}`<library>/<Author>/[<Series>/]<Book>/<Title>.m4b`.
      '';
    };

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/ripbook";
      description = ''
        Scratch space for intermediate WAVs and per-book resume state. Needs
        room for roughly 700 MB per disc, and must be writable by
        {option}`services.audiobookRipper.user`.
      '';
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/cdrom";
      description = "Optical drive to rip from.";
    };

    bitrate = lib.mkOption {
      type = lib.types.str;
      default = "64k";
      description = ''
        AAC bitrate for the finished m4b. 64k mono is the usual commercial
        audiobook target and is plenty for speech.
      '';
    };

    stereo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Encode stereo rather than downmixing to mono. Spoken word rarely needs
        it; turn it on for books with significant music or full-cast drama.
      '';
    };

    contact = lib.mkOption {
      type = lib.types.str;
      default = "ripbook";
      example = "you@example.com";
      description = ''
        Contact string sent in the User-Agent for MusicBrainz requests, as
        their API guidelines ask for.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        User who runs rips. Added to the `cdrom` group so the drive is readable
        over SSH, where the logind ACL that normally grants access does not apply.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ ripbook ];

    users.users.${cfg.user}.extraGroups = [ "cdrom" ];

    systemd.tmpfiles.rules = [
      "d ${cfg.workDir} 0755 ${cfg.user} users -"
    ];
  };
}
