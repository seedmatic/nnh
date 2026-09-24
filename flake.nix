{
  description = "nnh — unsampled network-flow observability appliance (pmacct probe + Akvorado collector)";

  inputs = {
    # Shared aggregator — keeps nnh in lock-step with the rest of the
    # seedmatic family (nix-darwin-home, rke2lab): nixpkgs + everything else we
    # borrow (flox, sops-nix, nixos-generators, disko, …) flow from here rather
    # than pinning our own. We only wire `follows` for the inputs we actually
    # consume today; the rest are pulled from flake-commons when a module needs them.
    flake-commons.url = "github:seedmatic/nix-flake-commons/develop";
    nixpkgs.follows = "flake-commons/nixpkgs";

    # Akvorado is nnh-specific — referenced DIRECTLY here, deliberately NOT
    # pushed up into flake-commons: nnh is the only project that consumes it.
    # The upstream flake ships the ready-built backend (Go binary with the pnpm
    # console embedded) as `packages.<system>.backend`, so we do no packaging —
    # only a `services.akvorado` module (see modules/akvorado.nix). Pinned to the
    # PoC's release tag so the config schema matches what we proved.
    #
    # We deliberately do NOT make akvorado follow our nixpkgs: that broke its
    # Go-modules fixed-output hash (vendorHash mismatch — its FOD is calibrated
    # against its own pinned nixpkgs). It builds against its own nixpkgs; we
    # consume only the resulting binary, so a second nixpkgs in the closure is fine.
    akvorado.url = "github:akvorado/akvorado/v2026.8.0";

    # ndh (nix-darwin-home) is the resolved source of truth for the home-LAN host
    # inventory: its catalog PROJECTS rke2lab's cluster blueprint AND adds the
    # daily-driver reservations, so `ndh.catalog.netplan.lan.hosts` is the complete
    # name→IP map (rke2lab alone only carries the cluster nodes). We consume its
    # catalog to label our own side with per-host names in the flow console — no
    # darwin build is realized.
    #
    # This is a MUTUAL (federated) dependency: nnh reads ndh's catalog while ndh
    # reads nnh's `lib.networkBlueprint` (its own `nnh` input). That cycle is broken
    # with `inputs.nnh.follows = ""` — an empty follows resolves to the ROOT flake
    # (this one), a fixpoint that terminates the recursion (see the hub memory
    # flake-mutual-dependency-follows-root). `inputs.flake-commons.follows` dedupes the
    # shared aggregator so ndh and nnh resolve the SAME nixpkgs/flox/… tree instead of
    # locking a second copy.
    ndh = {
      url = "github:seedmatic/ndh/develop";
      inputs.nnh.follows = "";
      inputs.flake-commons.follows = "flake-commons";
    };
  };

  outputs =
    inputs@{ self, nixpkgs, akvorado, ndh, ... }:
    let
      lib = nixpkgs.lib;

      # The probe runs on the bare-metal vz Mac (it MUST capture the host's own
      # physical en0 — see pkgs/nnh-probe.nix); the collector is a NixOS
      # Incus instance on nikopol-nixos (a Linux VM on the same Mac).
      probeSystem = "aarch64-darwin";
      collectorSystem = "aarch64-linux";

      probePkgs = nixpkgs.legacyPackages.${probeSystem};

      # ── Probe (migrated from ndh; nnh owns it now) ──────────────────────
      probe = probePkgs.callPackage ./pkgs/nnh-probe.nix { };

      # Deploy: push the (small) closure to the vz host over ssh, then render +
      # load the root LaunchDaemon via sudo. A push needs no reverse connection,
      # so it works from any operator wherever `ssh <vz-host>` resolves.
      # Default vz host: vzhost.nikopol.
      probeDeploy = probePkgs.writeShellApplication {
        # Binary lands in PATH (nix profile / devshell) → keep the disambiguating
        # nnh- prefix; `probe-deploy` alone is too generic. (The nix let-binding
        # above stays short — we're already in nnh.)
        name = "nnh-probe-deploy";
        runtimeInputs = [
          probePkgs.nix
          probePkgs.openssh
        ];
        text = builtins.readFile (
          probePkgs.replaceVars ./pkgs/nnh-probe.d/deploy.sh {
            bundle = "${probe}";
          }
        );
      };

      # Akvorado backend, patched for our macOS probe. pmacct on macOS can only
      # capture BOTH directions with NO pcap direction set, and in that mode it
      # cannot stamp an ifindex, so every flow arrives with InIf==OutIf==0 — which
      # upstream's enricher drops ("input and output interfaces missing"). Our
      # patch resolves those flows via a metadata lookup with ifindex 0 (the ::/0
      # static provider's `default` interface = en0/external) instead of dropping.
      # A ~25-line surgical diff kept as a patch (not a fork): we stay on the
      # pinned tag, it rebases trivially, and it's upstreamable as-is. It touches
      # no go.mod/go.sum, so akvorado's vendorHash (its own goModules FOD) is
      # unaffected — overrideAttrs only adds a patchPhase input.
      akvoradoBackend = akvorado.packages.${collectorSystem}.backend.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./pkgs/akvorado-enricher-ifindex0.patch ];
      });

      # ── Collector image (pure nix — NO distrobuilder, NO nixos-generators) ──
      # A plain nixosSystem importing nixpkgs' lxc-container profile. The build
      # products are `config.system.build.{squashfs,metadata}`, imported into the
      # nikopol-nixos Incus daemon with:
      #   incus image import <metadata>/tarball/*.tar.xz <squashfs> --alias nnh/collector
      # (Building the aarch64-linux image needs a linux builder.)
      # Attribution data from ndh's catalog — the SINGLE source of truth for
      # "your side" naming, consumed as pure data (no darwin build realized):
      #   segments : [{cidr,name,asn}]  → prefix→{name,asn}, most-specific-wins
      #   asns     : {"<asn>" = name}   → the canonical AS-name dictionary
      #   hosts    : name→{ip,mac,kind} → per-host /32 NetNames (daily-drivers +
      #              rke2 nodes projected from rke2lab)
      # This replaces nnh's former hardcoded selfBase/gatewayNetworks/asns.
      # nnh keeps `ndh` as a flake input and consumes it LIVE at eval; the mutual
      # dependency (ndh unioning nnh's blueprint) is broken with reciprocal
      # `inputs.<other>.inputs.<self>.follows = ""` — added in lock-step with ndh
      # when/if nnh contributes a span (see the hub memory
      # flake-mutual-dependency-follows-root). Today nnh owns no span (both
      # instances are DHCP tenants of ndh's fabric-br /21), so it is a pure consumer.
      ndhHosts = ndh.catalog.netplan.lan.hosts;
      ndhSegments = ndh.catalog.netplan.segments;
      ndhAsns = ndh.catalog.netplan.asns;

      # The pipeline is split across TWO Incus instances, both on fabric-br, along a
      # failure-domain line:
      #   nnh-inlet  — ingest edge + brain (orchestrator + inlet + Kafka)
      #   nnh-outlet — store (outlet + console + ClickHouse/Redis + GeoIP)
      # Co-locating orchestrator+Kafka with the inlet makes ingest self-contained: it
      # buffers to a local Kafka and serves its own config, so a store outage loses no
      # flows. Both hosts take the same specialArgs — the inlet's attribution `let`
      # consumes the ndh* attrs (it now holds the `settings`); passing them uniformly
      # keeps the wiring simple (outlet's module ignores the extras via its `...`).
      mkCollectorSystem =
        hostFile:
        lib.nixosSystem {
          system = collectorSystem;
          specialArgs = { inherit inputs akvoradoBackend ndhSegments ndhAsns ndhHosts; };
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
            hostFile
          ];
        };
      inletSystem = mkCollectorSystem ./hosts/inlet.nix;
      outletSystem = mkCollectorSystem ./hosts/outlet.nix;

      # The ONE /30 nnh owns, declared once and consumed three times: the blueprint
      # contribution below, and the two instance pins (mkProfile's ipv4.address). It used
      # to be five literals; ndh held a sixth and seventh copy in `staticHosts`, which is
      # what made them able to disagree. ndh now derives its dnsmasq host-records from the
      # segment published here, so moving this /30 is a one-line change on this side.
      #
      # It stays a LITERAL rather than reading ndh's catalog, and that is not laziness: ndh
      # MERGES this blueprint into that catalog, so reading it back would close a real value
      # cycle. (nnh reads ndh's catalog elsewhere — just not from the contribution ndh
      # consumes.) The flake-level mutual dependency is broken separately, with reciprocal
      # `inputs.<other>.inputs.<self>.follows = ""` (see the hub memory
      # flake-mutual-dependency-follows-root).
      #
      # POSITION. ndh's fabric slice for a bare-metal is derived from rke2lab's hostId:
      # 172.16.<hostId*16>.0/20, whose low eight /24s are the fabric-br L2. Slot 0 of that
      # half is host infra — gateway .1, the dynamic DHCP pool .2-.30 — and pinned tenants
      # live above the pool, filled top-down. nikopol is hostId 1, so slot 0 is
      # 172.16.16.0/24 and nnh takes .124/30 in it (usable .125/.126). Previously this read
      # "the top /30 of bare-br's /25" (172.16.6.124/30) — that bridge has since been renamed
      # fabric-br and its net widened to a /21, so the anchor is slot 0, not the top of the net.
      #
      # OWNERSHIP boundary: ndh owns the slice and its carve; nnh owns exactly this /30 and
      # its two hosts, and publishes ONLY that — never the enclosing net. ndh unions it in,
      # and akvorado's most-specific-prefix match makes the /30 win over the enclosing span
      # for .124-.127.
      collector = rec {
        base = "172.16.16";
        cidr = "${base}.124/30";
        inletAddress = "${base}.126";
        outletAddress = "${base}.125";
      };

      # What nnh CONTRIBUTES back to ndh's catalog (the "publish" side of the federation).
      networkBlueprint = {
        segments = [
          {
            cidr = collector.cidr;
            name = "nnh-collector";
            asn = 65000;
            hosts = [
              {
                name = "nnh-inlet";
                ip = collector.inletAddress;
              }
              {
                name = "nnh-outlet";
                ip = collector.outletAddress;
              }
            ];
          }
        ];
        asns = { }; # nnh introduces no new AS numbers
      };

      # ── Collector deploy (darwin operator tool) ─────────────────────────────
      # The Incus client is Linux-only as a daemon, but nixpkgs ships a
      # Darwin-buildable client (`incus.passthru.client`); the operator runs this
      # on the workstation and it drives the nikopol-nixos remote (creds in
      # ~/.config/incus, shared with rke2lab).
      incusClient = probePkgs.incus.passthru.client;

      # Incus profiles, generated from Nix (a heredoc would break on `''` stripping).
      # Single NIC lan0 bridged to `fabric-br` — nikopol's ndh-provisioned segment
      # (.nikopol dnsmasq zone + the slice advertised into the tailnet).
      # `ipv4.address` PINS a STATIC lease: slot 0 of that segment is carved dynamic-low
      # (a /27, ndh's dhcp.ranges) then pinned tenants above it, and the collector takes
      # the /30 declared in `collector`. This stops a fabric-br recreate from re-shuffling the
      # instance IPs — which had wedged akvorado's Kafka clients (advertised by name)
      # and left the probe exporting to a stale IP. Incus records the reservation in
      # fabric-br's dnsmasq, and `dns.mode=dynamic` still maps nnh-*.nikopol → the pin.
      # security.nesting eases NixOS's nested systemd mounts in an unprivileged
      # container. Persistent volumes differ by role.
      mkProfile =
        { description, ipv4Address, extraDevices }:
        (probePkgs.formats.yaml { }).generate "nnh-profile.yaml" {
          config."security.nesting" = "true";
          inherit description;
          devices = {
            root = {
              type = "disk";
              path = "/";
              pool = "default";
            };
            lan0 = {
              type = "nic";
              nictype = "bridged";
              parent = "fabric-br";
              name = "lan0";
              "ipv4.address" = ipv4Address;
            };
          }
          // extraDevices;
        };

      # nnh-inlet: no persistent volumes despite running orchestrator + inlet + Kafka —
      # all of it is reconstructible (orchestrator config is baked in nix, Kafka is a
      # ≤1-day buffer that's ephemeral BY DESIGN). Nothing here needs to survive a rebuild.
      inletProfileYaml = mkProfile {
        description = "nnh-inlet (ingest edge + brain)";
        # The inlet takes the high address of nnh's /30; see `collector` for the position.
        ipv4Address = collector.inletAddress;
        extraDevices = { };
      };

      # nnh-outlet: the ClickHouse flow history (data) + akvorado runtime state (the
      # GeoIP mmdbs AND console.sqlite — saved filters/users) + the tailscale node
      # identity, each on its OWN project-scoped volume so an `incus rebuild` keeps
      # them (and none has to migrate the others). Without the akvorado volume,
      # /var/lib/akvorado sat on the ephemeral rootfs and every rebuild re-fetched
      # GeoIP from scratch, hammering the free tier into HTTP 429.
      outletProfileYaml = mkProfile {
        description = "nnh-outlet (store)";
        ipv4Address = collector.outletAddress; # paired with the inlet; see `collector`
        extraDevices = {
          data = {
            type = "disk";
            pool = "default";
            source = "data"; # volume names are project-scoped (project nnh)
            path = "/var/lib/clickhouse";
          };
          akvorado = {
            type = "disk";
            pool = "default";
            source = "akvorado";
            path = "/var/lib/akvorado";
          };
          tailscale = {
            type = "disk";
            pool = "default";
            source = "tailscale";
            path = "/var/lib/tailscale";
          };
        };
      };

      # Builds BOTH aarch64-linux images (via the /etc/nix/machines remote builder),
      # then brings the two-instance appliance up in its own `nnh` Incus project:
      # ensures project + the outlet's persistent volumes + both profiles, imports
      # each split image (metadata + squashfs), and launches nnh-inlet + nnh-outlet
      # on fabric-br — or, if an instance already exists, `incus rebuild`s it from the
      # new image (keeps the volumes, so the ClickHouse flow history survives).
      collectorDeploy = probePkgs.writeShellApplication {
        name = "collector-deploy";
        # The incus client shells out to `tar` (+ `xz`) to read each split image's
        # metadata .tar.xz on import. writeShellApplication gives a curated PATH, so
        # both must be listed (mirrors the gnutar+xz added to the flox env).
        runtimeInputs = [
          incusClient
          probePkgs.gnutar
          probePkgs.xz
          probePkgs.yq-go # robust YAML parsing of incus list output (exact-name checks)
        ];
        text = builtins.readFile (
          probePkgs.replaceVars ./pkgs/collector-deploy.d/collector-deploy.sh {
            inletMetadata = "${inletSystem.config.system.build.metadata}";
            inletSquashfs = "${inletSystem.config.system.build.squashfs}";
            inletProfile = "${inletProfileYaml}";
            outletMetadata = "${outletSystem.config.system.build.metadata}";
            outletSquashfs = "${outletSystem.config.system.build.squashfs}";
            outletProfile = "${outletProfileYaml}";
            # Chain the upstream probe deploy at the end (collector first, then probe).
            probeDeploy = "${probeDeploy}/bin/nnh-probe-deploy";
          }
        );
      };
    in
    {
      # Output attrs are SHORT — we're already in nnh, so the namespace is implicit
      # (`nix run .#probe-deploy`). Only the PATH binary keeps the nnh- prefix
      # (writeShellApplication name above) — there `probe-deploy` alone is too generic.
      packages.${probeSystem} = {
        probe = probe;
        probe-deploy = probeDeploy;
        collector-deploy = collectorDeploy;
      };

      packages.${collectorSystem} = {
        inlet-squashfs = inletSystem.config.system.build.squashfs;
        inlet-metadata = inletSystem.config.system.build.metadata;
        outlet-squashfs = outletSystem.config.system.build.squashfs;
        outlet-metadata = outletSystem.config.system.build.metadata;
      };

      # One attrset per dynamic system key: Nix can't merge two separate
      # `apps.${probeSystem}.<x>` bindings (dynamic attributes don't combine).
      apps.${probeSystem} = {
        probe-deploy = {
          type = "app";
          program = "${probeDeploy}/bin/nnh-probe-deploy";
          meta.description = "Push the nnh-probe closure to the vz Mac + load its root LaunchDaemon (pmacctd → nnh-inlet.nikopol:2055) — docs: https://github.com/seedmatic/nnh/blob/main/docs/architecture.adoc";
        };
        collector-deploy = {
          type = "app";
          program = "${collectorDeploy}/bin/collector-deploy";
          meta.description = "Build both images + bring up the two-instance appliance (nnh-inlet + nnh-outlet) on fabric-br in the nnh Incus project — docs: https://github.com/seedmatic/nnh/blob/main/docs/architecture.adoc";
        };
      };

      nixosConfigurations = {
        inlet = inletSystem;
        outlet = outletSystem;
      };

      # The federation contribution ndh unions into its catalog (see the
      # networkBlueprint `let` above): nnh's two fabric-br hosts, names only.
      lib.networkBlueprint = networkBlueprint;
    };
}
