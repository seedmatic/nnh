# Shared base for both nnh collector instances (nnh-inlet, nnh-outlet).
#
# The pipeline is split across TWO NixOS Incus instances, BOTH attached to
# nikopol's `bare-br` segment (ndh-provisioned: DHCP + a `.nikopol` dnsmasq zone,
# the slice advertised into the tailnet). Each instance gets a pinned lease in that
# segment (the /30 nnh owns — see `collector` in flake.nix) and
# auto-registers as `<hostName>.nikopol`, so they reach each other — and the probe
# reaches the inlet — BY NAME, independent of the carrier hotspot. This replaces
# the former single-box hand-rolled /30 on the Wi-Fi bridge.
{
  config,
  lib,
  pkgs,
  akvoradoBackend,
  ...
}:
{
  imports = [ ../modules/akvorado.nix ];

  # Single bridged NIC `lan0` on bare-br, DHCP only: the lease carries the address
  # (pinned via the profile's ipv4.address), the .nikopol name registration (dnsmasq keys off the hostname the
  # DHCP client sends = networking.hostName), the default route (internet, for the
  # GeoIP fetch on the outlet) and the resolver. No static address: bare-br owns it.
  networking.useDHCP = false; # kill the deprecated per-interface catch-all
  networking.interfaces.lan0.useDHCP = true;

  # Single-purpose appliance on an internal segment; every backend that must stay
  # private binds localhost, and the ports we DO expose on bare-br (inlet :2055,
  # kafka :9092, orchestrator :8080, console :8083, ssh) are the ones the peer
  # instance / probe / operator need. A firewall here would only risk dropping them.
  networking.firewall.enable = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # ClickHouse (and clickhouse-client) need the zoneinfo database; the minimal LXC
  # image ships none. Pin UTC and expose tzdata where ClickHouse looks. Harmless on
  # the inlet (no ClickHouse there), kept in common so both images are identical.
  time.timeZone = "UTC";
  systemd.tmpfiles.rules = [
    "L+ /usr/share/zoneinfo - - - - ${pkgs.tzdata}/share/zoneinfo"
  ];

  # Akvorado itself: enabled on both, same patched backend; each host sets its own
  # `daemons` list (and the outlet carries the orchestrator `settings`).
  services.akvorado = {
    enable = true;
    package = akvoradoBackend;
  };

  system.stateVersion = "26.05";
}
