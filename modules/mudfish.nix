{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.mudfish;

  # The vendor bakes this prefix into every binary (see pkgs/mudfish), so the
  # bind-mount targets below must be derived from the package's own version
  # rather than written out by hand -- a version bump then moves the mounts
  # automatically instead of silently pointing at a path the daemon ignores.
  prefix = "/opt/mudfish/${cfg.package.version}";

  # Mudfish's own default launcher port. Kept as a literal so the module can
  # avoid passing -P at all in the default case: passing -P with any value,
  # including 8282 itself, makes the daemon emit
  # "[ERROR] Mudfish Launcher uses the port N instead of 8282" (MUDEC_00014).
  # It is non-fatal, but there is no reason to put a spurious ERROR line in the
  # journal on every start.
  defaultPort = 8282;
in {
  # ---------------------------------------------------------------------------
  # OPTIONS
  # ---------------------------------------------------------------------------
  options.services.mudfish = {
    enable = lib.mkEnableOption "Mudfish Cloud VPN route-optimising daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/mudfish {};
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/mudfish {}";
      description = "The Mudfish package providing mudrun-headless.";
    };

    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wlp194s0";
      description = ''
        Uplink interface the web UI firewall hole is punched on. Only consulted
        when {option}`services.mudfish.openWebUI` is true. Left as null by
        default so the interface name is stated by the host that owns the
        hardware, rather than hardcoded in a shared module.
      '';
    };

    webUIPort = lib.mkOption {
      type = lib.types.port;
      default = defaultPort;
      description = ''
        Port for Mudfish's local launcher web UI, where you log in and equip
        items. Changing this away from 8282 causes the daemon to log a
        non-fatal MUDEC_00014 notice on every start.
      '';
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the launcher web UI binds. Defaults to loopback: the UI is an
        unauthenticated control surface for the tunnel, so exposing it on the
        LAN is opt-in via this option plus {option}`openWebUI`.
      '';
    };

    openWebUI = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open {option}`webUIPort` on {option}`interface` in the firewall. Only
        useful together with a non-loopback {option}`listenAddress`; with the
        default loopback bind there is nothing on the wire to reach.
      '';
    };

    autoLogin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set the mudrun.autologin launcher parameter. Off by default in the
        vendor's own configuration, which is a common reason a headless
        install appears to start cleanly and then never authenticates.
      '';
    };

    autoConnect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set the mudrun.autoconnect launcher parameter. Also off by default
        upstream: without it the daemon runs and serves its web UI but never
        brings a tunnel up, so no tun interface appears.
      '';
    };

    credentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/mudfish-credentials.env";
      description = ''
        Optional path to an EnvironmentFile (outside the Nix store, so it is
        not world-readable in /nix/store) defining MUDFISH_USERNAME and
        MUDFISH_PASSWORD.

        Leaving this null is the recommended path: log in once through the
        local web UI and the daemon persists a JWT into its state directory
        (mudrun.jwt in var/.snapshot.db), so credentials never have to appear
        on a command line where {manpage}`ps(1)` can read them.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["-A"];
      description = "Extra flags appended to the mudrun-headless invocation.";
    };
  };

  # ---------------------------------------------------------------------------
  # IMPLEMENTATION
  # ---------------------------------------------------------------------------
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.openWebUI -> cfg.interface != null;
        message = "services.mudfish.openWebUI requires services.mudfish.interface to be set.";
      }
    ];

    # Mudfish is redistributed as a closed-source vendor binary. Declaring the
    # allowance here, rather than expecting the consuming host to remember a
    # separate allowlist entry, keeps the module self-contained: the flake's own
    # `packages` output sets allowUnfree on its private nixpkgs instantiation,
    # but a nixosConfiguration builds its own pkgs and inherits none of that.
    # A predicate is used instead of a blanket allowUnfree so enabling Mudfish
    # does not quietly unlock every other unfree package in the system closure.
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) ["mudfish"];

    # mudadm/mudmtr/muddiag on PATH for diagnosis; also pulls the tray GUI's
    # .desktop file into the session for the Hyprland user.
    environment.systemPackages = [cfg.package];

    # The daemon opens /dev/net/tun directly. On this kernel the node already
    # exists, but requesting the module keeps the unit correct on a kernel where
    # tun is modular and nothing else has caused it to load first.
    boot.kernelModules = ["tun"];

    # The vendor's absolute prefix has to be mountable, and NixOS has no /opt at
    # all. This creates it empty and leaves it empty: the actual contents only
    # ever exist inside the service's private mount namespace, so the host
    # filesystem gains a bare directory and nothing else. This is what keeps the
    # package purely declarative instead of unpacking a vendor tree into /opt.
    systemd.tmpfiles.rules = ["d /opt 0755 root root -"];

    networking.firewall.interfaces = lib.mkIf cfg.openWebUI {
      "${cfg.interface}".allowedTCPPorts = [cfg.webUIPort];
    };

    systemd.services.mudfish = {
      description = "Mudfish Cloud VPN route-optimising daemon";
      wantedBy = ["multi-user.target"];

      # The daemon resolves and probes Mudfish relay nodes during startup (the
      # rtt prober fires within the first second), so it needs real routing, not
      # merely a configured link.
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        # Verified by running the binary: with -r it stays in the foreground and
        # writes its log to stdout. WITHOUT -r it double-forks and redirects
        # into var/mudrun_stdout.txt, which would leave `journalctl -u mudfish`
        # showing nothing but "Started" -- the exact symptom of a service that
        # looks healthy while telling you nothing. Type=exec therefore pairs
        # with -r below; neither is optional.
        Type = "exec";

        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/opt/mudfish/${cfg.package.version}/bin/mudrun-headless"

            # Do not try to spawn a browser. Harmless under systemd (it already
            # skips this when SUDO_USER is unset) but explicit beats incidental.
            "-B"

            # Use the tun(4) driver. The mudrun.tuntap_driver parameter defaults
            # to "tap", so without -N the daemon creates a tap interface and
            # `ip a show tun0` finds nothing.
            "-N"

            # Disable the vendor's stdout-to-file redirection so the log lands
            # in the journal. See the Type=exec note above.
            "-r"
          ]
          # NOT passed: -i. That flag is "Enable WSL (Windows Subsystem for
          # Linux) mode" per the binary's own usage output. It is correct only
          # under WSL and has no business on bare metal.
          ++ lib.optionals (cfg.webUIPort != defaultPort) ["-P" (toString cfg.webUIPort)]
          ++ lib.optionals (cfg.listenAddress != "127.0.0.1") ["-a" cfg.listenAddress]
          ++ lib.optionals cfg.autoLogin ["-C" "mudrun.autologin=on"]
          ++ lib.optionals cfg.autoConnect ["-C" "mudrun.autoconnect=on"]
          # Credentials come from the EnvironmentFile when one is configured.
          # systemd expands $VAR in ExecStart without a shell, so the values
          # never transit a shell command line.
          ++ lib.optionals (cfg.credentialsFile != null) ["-u" "$MUDFISH_USERNAME" "-p" "$MUDFISH_PASSWORD"]
          ++ cfg.extraArgs
        );

        EnvironmentFile = lib.mkIf (cfg.credentialsFile != null) cfg.credentialsFile;

        # /var/lib/mudfish. Holds the pidfiles and .snapshot.db, which is where
        # the JWT from a web-UI login persists -- so this directory is what
        # makes credential-free restarts work.
        StateDirectory = "mudfish";
        StateDirectoryMode = "0700";

        # -- Namespace: reconstruct the vendor's absolute prefix -------------
        # /opt is a tmpfs private to this unit, the immutable tree is bound in
        # read-only straight from the store, and only var/ is writable. The
        # result satisfies the hardcoded /opt/mudfish/<version>/... lookups
        # while the host's own /opt stays an empty directory.
        TemporaryFileSystem = ["/opt:mode=755"];
        BindReadOnlyPaths = ["${cfg.package}/opt/mudfish/${cfg.package.version}:${prefix}"];
        BindPaths = ["/var/lib/mudfish:${prefix}/var"];

        # -- Privilege -------------------------------------------------------
        # Runs as root, deliberately and against the usual preference. mudrun
        # performs an explicit uid test at startup and aborts with
        # "Mudfish Launcher (mudrun) MUST be run as administrator or root"
        # (MUDEC_00001, RUN_init:696). This was verified to be a uid check and
        # not a capability check: granting the binary a fake uid 0 in a user
        # namespace with zero real capabilities gets it past the test, while a
        # non-root uid holding CAP_NET_ADMIN would not. There is therefore no
        # User= that works short of patching the vendor binary.
        #
        # The bounding set below is the compensation: root here keeps only the
        # capabilities the daemon's actual job needs, so a compromise of it does
        # not inherit full root authority.
        #
        #   CAP_NET_ADMIN - create and configure the tun interface, install the
        #                   routes and packet marks that steer game traffic
        #   CAP_NET_RAW   - the bundled mudovpn/rtt prober use raw sockets for
        #                   latency probing to candidate relay nodes
        #
        # If journalctl shows a permissions failure, add the one specific
        # capability named in the error and record why here. Do not widen to
        # CAP_SYS_ADMIN, which is effectively root again.
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
        NoNewPrivileges = true;

        # -- Sandbox ---------------------------------------------------------
        # ProtectSystem=strict makes the whole filesystem read-only apart from
        # StateDirectory and the binds above, which matters more than usual here
        # because the process is uid 0.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;

        # Deliberately NOT PrivateNetwork (it manages the host's network) and
        # NOT PrivateDevices, which would hide /dev/net/tun and break the whole
        # point of the service.
        DeviceAllow = ["/dev/net/tun rw"];

        RestrictAddressFamilies = [
          "AF_UNIX" # local IPC between mudrun and its mudflow/mudfish children
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK" # interface and route manipulation
          "AF_PACKET" # raw probing, paired with CAP_NET_RAW
        ];

        # The relay probe can stall on an unreachable node rather than failing
        # fast, so restart rather than sit in a half-started state.
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
