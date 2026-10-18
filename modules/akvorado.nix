# services.akvorado — the four Akvorado daemons under NATIVE systemd.
#
# Akvorado is a 4-process pipeline: the orchestrator reads the rendered
# akvorado.yaml and serves per-daemon config over HTTP; inlet/outlet/console
# fetch their config from `orchestratorUrl`. We run them as plain systemd units,
# NOT under Docker/podman — the netavark UDP hostport DNAT is unreliable and was
# the root cause of a long capture-loss red herring (see CLAUDE.md). The inlet
# binds its NetFlow UDP port directly.
#
# Because the daemons no longer live in separate containers, each one's own
# `http.listen` MUST be a distinct port (in docker every container bound :8080).
# Set them in `settings.{http,inlet.http,outlet.http,console.http}.listen`.
#
# Nobody upstream ships a services.akvorado module (akvorado discussions #1740);
# this is authored here. `settings` is freeform (rendered to YAML), so the
# nnh-specific pipeline (static ::/0 exporter, geoip, filters) lives in the
# host config, not here.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.akvorado;
  format = pkgs.formats.yaml { };
  configFile = format.generate "akvorado.yaml" cfg.settings;

  # Split-safe dependency helpers: a daemon only orders after a backend when that
  # backend runs on THIS host (single-box = all local; split = kafka on ingest,
  # clickhouse/redis on the store node). Remote backends are reached over the
  # network and just retried, so they need no systemd ordering.
  runs = name: builtins.elem name cfg.daemons;
  kafkaDep = lib.optional config.services.apache-kafka.enable "apache-kafka.service";
  clickhouseDep = lib.optional config.services.clickhouse.enable "clickhouse.service";
  redisDep = lib.optional (config.services.redis.servers ? "") "redis.service";
  orchestratorDep = lib.optional (runs "orchestrator") "akvorado-orchestrator.service";
  geoipDep = lib.optional cfg.geoip.enable "akvorado-geoip.service";

  # One daemon unit. `after`/`wants` are list-typed options, so mkMerge
  # concatenates the base and per-daemon entries rather than overriding.
  daemon =
    name: extra:
    lib.mkMerge [
      {
        description = "Akvorado ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          User = "akvorado";
          Group = "akvorado";
          StateDirectory = "akvorado";
          Restart = "on-failure";
          RestartSec = 5;
          # The daemons retry their orchestrator/kafka/clickhouse connections, so
          # a backend not-yet-ready is not fatal — just restart until it settles.
        };
      }
      extra
    ];
in
{
  options.services.akvorado = {
    enable = lib.mkEnableOption "the Akvorado flow collector (native systemd, no Docker)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The akvorado backend package (must provide bin/akvorado).";
    };

    orchestratorUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8080";
      description = "URL where inlet/outlet/console fetch their config from the orchestrator.";
    };

    daemons = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "orchestrator"
          "inlet"
          "outlet"
          "console"
        ]
      );
      default = [
        "orchestrator"
        "inlet"
        "outlet"
        "console"
      ];
      description = ''
        Which Akvorado daemons to run on THIS host. Single-box deploys run all
        four; a split deploy runs e.g. [orchestrator inlet] on the ingest node and
        [outlet console] on the store node. Only the orchestrator needs `settings`
        (the full config it serves); the others fetch theirs from `orchestratorUrl`.
        Each daemon's systemd unit is created only when listed here, and its
        after/wants track only the backends enabled locally (clickhouse/kafka/redis).
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        The orchestrator aggregate config, rendered to /etc/akvorado/akvorado.yaml.
        Top-level `http.listen` is the orchestrator's own port; each daemon's port
        goes in `inlet.http.listen`, `outlet.http.listen`, `console.http.listen`.
      '';
    };

    geoip = {
      enable = lib.mkEnableOption "the periodic GeoIP database fetch";
      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/akvorado/geoip";
        description = "Where the fetched .mmdb files land (referenced by outlet.geoip.*-database).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.akvorado = {
      isSystemUser = true;
      group = "akvorado";
    };
    users.groups.akvorado = { };

    environment.etc."akvorado/akvorado.yaml".source = configFile;

    systemd.services.akvorado-orchestrator = lib.mkIf (runs "orchestrator") (
      daemon "orchestrator" {
        after = clickhouseDep ++ kafkaDep;
        wants = clickhouseDep ++ kafkaDep;
        serviceConfig.ExecStart = "${cfg.package}/bin/akvorado orchestrator /etc/akvorado/akvorado.yaml";
      }
    );

    systemd.services.akvorado-inlet = lib.mkIf (runs "inlet") (
      daemon "inlet" {
        after = orchestratorDep ++ kafkaDep;
        wants = orchestratorDep ++ kafkaDep;
        serviceConfig.ExecStart = "${cfg.package}/bin/akvorado inlet ${cfg.orchestratorUrl}";
      }
    );

    systemd.services.akvorado-outlet = lib.mkIf (runs "outlet") (
      daemon "outlet" {
        after = orchestratorDep ++ kafkaDep ++ clickhouseDep ++ geoipDep;
        wants = orchestratorDep ++ kafkaDep ++ clickhouseDep ++ geoipDep;
        serviceConfig.ExecStart = "${cfg.package}/bin/akvorado outlet ${cfg.orchestratorUrl}";
      }
    );

    systemd.services.akvorado-console = lib.mkIf (runs "console") (
      daemon "console" {
        after = orchestratorDep ++ redisDep ++ clickhouseDep;
        wants = orchestratorDep ++ redisDep ++ clickhouseDep;
        serviceConfig.ExecStart = "${cfg.package}/bin/akvorado console ${cfg.orchestratorUrl}";
      }
    );

    # GeoIP: ASN names + city/state from free, tokenless jsdelivr mirrors
    # (ip-location-db GeoLite2-ASN + wp-statistics GeoLite2-City). Akvorado has no
    # reverse-DNS, so this is how destinations get org + location. optional:true
    # in the outlet config tolerates a not-yet-fetched db on first boot.
    systemd.services.akvorado-geoip = lib.mkIf cfg.geoip.enable {
      description = "Fetch Akvorado GeoIP databases (GeoLite2-ASN + GeoLite2-City mirrors)";
      # network-online is unreliable in an LXC container (it goes active before the
      # DHCP default route is up), so the curl retries in geoip-fetch.sh are the
      # real resilience; nss-lookup.target is defensive ordering for the DNS lookup.
      after = [
        "network-online.target"
        "nss-lookup.target"
      ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.curl
        pkgs.gzip
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "akvorado";
        Group = "akvorado";
        StateDirectory = "akvorado";
      };
      script = import ../nix/replace-vars-text.nix lib ./akvorado.d/geoip-fetch.sh {
        geoipDir = cfg.geoip.directory;
      };
    };

    systemd.timers.akvorado-geoip = lib.mkIf cfg.geoip.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "48h";
        Persistent = true;
      };
    };
  };
}
