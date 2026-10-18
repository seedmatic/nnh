# NetFlow probe for the bare-metal vz host (nikopol-vz).
#
# The traffic the operator wants to account for — the MacBook's own uplink to
# the Android hotspot — only exists on the bare metal's physical Wi-Fi (en0): a
# Tart guest bridged to that Wi-Fi never sees the host's own unicast (switched
# L2), so the probe MUST run on the bare metal, not in a VM.
#
# We use pmacct's `pmacctd` (libpcap capture) with the `nfprobe` plugin rather
# than softflowd: the goal is EXACT byte accounting to match a carrier bill, so
# every flow must be counted — `sampling_rate: 1` (no renormalisation) and a
# per-flow NetFlow v9 record carrying the real cumulative byte count. softflowd
# also could not satisfy Akvorado's enricher gates (it emits no interface index
# and no exporter metadata); pmacct assigns a static ifindex via
# `pcap_ifindex: map` + interfaces.map, which the Akvorado static metadata
# provider then resolves.
#
# nikopol-vz is outside the ndh nix-darwin fleet (it has a nix store + flox but
# no darwin-rebuild activation), so this bundle carries pmacct plus a root
# LaunchDaemon installer that renders the config + interfaces.map + plist at
# deploy time — mirroring how nerd-tart lands a per-VM YAML on the vz host
# rather than baking it into a system module.  It is copied over via the same
# `nix copy` rail as the Tart artifacts (see `nnh-probe-deploy` in flake.nix).
{
  lib,
  pmacct,
  coreutils,
  writeShellApplication,
  symlinkJoin,
}:
let
  label = "io.nxmatic.nnh-probe";
  plistPath = "/Library/LaunchDaemons/${label}.plist";
  logPath = "/var/log/nnh-probe.log";
  confDir = "/etc/nnh-probe";

  # The default pmacct build pulls in Linux-only deps (libnetfilter_log for
  # NFLOG, numactl via the MySQL feature) that refuse to evaluate on Darwin.
  # The nfprobe plugin needs only libpcap, so drop every optional backend.
  pmacctd = pmacct.override {
    withNflog = false;
    withMysql = false;
    withPgSQL = false;
    withKafka = false;
    withSQLite = false;
  };

  install = writeShellApplication {
    name = "nnh-probe-install";
    runtimeInputs = [ coreutils ];
    text = import ../nix/replace-vars-text.nix lib ./nnh-probe.d/install.sh {
      pmacctd = "${pmacctd}";
      label = label;
      plist = plistPath;
      log = logPath;
      confDir = confDir;
    };
  };

  uninstall = writeShellApplication {
    name = "nnh-probe-uninstall";
    runtimeInputs = [ coreutils ];
    text = import ../nix/replace-vars-text.nix lib ./nnh-probe.d/uninstall.sh {
      label = label;
      plist = plistPath;
      confDir = confDir;
    };
  };
in
symlinkJoin {
  name = "nnh-probe";
  paths = [
    install
    uninstall
    pmacctd
  ];
  meta = {
    description = "pmacct nfprobe NetFlow probe + root LaunchDaemon installer for the bare-metal vz host";
    platforms = lib.platforms.darwin;
    mainProgram = "nnh-probe-install";
  };
}
