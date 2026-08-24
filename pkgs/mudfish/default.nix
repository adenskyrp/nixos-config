{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  # --- Runtime shared libraries -------------------------------------------
  # Every entry below was derived from `patchelf --print-needed` run against all
  # 12 shipped ELFs, then re-verified with `ldd` against the built output. None
  # of these are guesses.
  openssl,
  zlib,
  elfutils,
  glib,
  gtk3,
  libayatana-appindicator,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mudfish";
  version = "6.5.4";

  # ---------------------------------------------------------------------------
  # UPSTREAM ARTIFACT
  # ---------------------------------------------------------------------------
  # Mudfish publishes only a self-extracting installer per release; there is no
  # tarball and no source. The version is pinned explicitly rather than tracking
  # "latest" because the vendor bakes the version string into absolute runtime
  # paths (see installPhase), so an upstream bump must be a deliberate edit here
  # -- otherwise the package would desynchronise from the systemd unit's bind
  # mounts and fail at activation rather than at eval.
  src = fetchurl {
    url = "https://mudfish.net/releases/mudfish-${finalAttrs.version}-linux-x86_64.sh";
    hash = "sha256-/+l6Zk+wjVsAA6GzXvZo1sXVCc5EYxzlOYQSv0lnDAw=";
  };

  nativeBuildInputs = [autoPatchelfHook];

  # ---------------------------------------------------------------------------
  # DT_NEEDED CLOSURE
  # ---------------------------------------------------------------------------
  # Measured union of `patchelf --print-needed` across the shipped binaries:
  #
  #   libc / libm / libgcc_s / ld-linux  -> stdenv (implicit)
  #   libssl.so.3, libcrypto.so.3       -> openssl   (sbin/mudovpn)
  #   libz.so.1                         -> zlib
  #   libelf.so.1                       -> elfutils
  #   libgio/libgobject-2.0.so.0        -> glib      (bin/mudrun only)
  #   libgtk-3.so.0                     -> gtk3      (bin/mudrun only)
  #   libayatana-appindicator3.so.1     -> libayatana-appindicator (bin/mudrun only)
  #
  # The GTK/appindicator trio is reachable only from bin/mudrun, the tray GUI.
  # The headless daemon path (mudrun-headless -> mudfish/mudflow/mudovpn) needs
  # nothing beyond libc/libm and openssl. They are kept so autoPatchelf does not
  # fail on mudrun and so the tray stays usable in the Hyprland session.
  #
  # ncurses is deliberately ABSENT -- see the mudstat note in installPhase.
  buildInputs = [
    openssl
    zlib
    elfutils
    glib
    gtk3
    libayatana-appindicator
  ];

  # ---------------------------------------------------------------------------
  # EXTRACT-ONLY UNPACK
  # ---------------------------------------------------------------------------
  # The installer is a Makeself 2.5.0 archive (verified: line 2 of the .sh reads
  # "This script was generated using Makeself 2.5.0"). Its embedded setup script
  # is ./bin/pkg_linux_setup.sh, which requires root and writes to /opt directly
  # -- exactly what must not happen inside a Nix build. `--noexec` extracts the
  # payload and skips that script; `--target` redirects extraction out of
  # $TMPDIR/selfgz$$ into a path we control. Verified to exit 0 and to produce
  # bin/ sbin/ etc/ share/ with no side effects outside the target directory.
  #
  # `--noexec` still runs the archive's own MD5 integrity check, which only
  # reads the archive itself and is therefore safe in a sandbox.
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    sh $src --noexec --target ./payload

    runHook postBuild
  '';

  # ---------------------------------------------------------------------------
  # INSTALL: PRESERVE THE VENDOR'S ABSOLUTE PREFIX
  # ---------------------------------------------------------------------------
  # The binaries hardcode "/opt/mudfish/<version>/" with no environment-variable
  # override (confirmed via `strings`: /opt/mudfish/6.5.4/bin/mudadm,
  # .../var/mudrun.pid, .../etc/htdocs-www-6.5.4.tar, and exec templates such as
  # ".../bin/mudfish -G %d -R -u %s -p %s"). mudrun-headless does not locate its
  # siblings relative to argv[0] -- it builds those absolute paths and execs
  # them.
  #
  # So the store layout mirrors that prefix exactly, and modules/mudfish.nix
  # bind-mounts $out/opt/mudfish/<version> onto /opt/mudfish/<version> inside a
  # private mount namespace. /nix/store stays authoritative, the real host /opt
  # is never written, and the hardcoded lookups still resolve. Flattening this
  # directory would break the daemon at runtime, not at build time.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/mudfish/${finalAttrs.version}
    cp -r payload/* $out/opt/mudfish/${finalAttrs.version}/

    # The vendor's root-requiring installer is dead weight in the store and an
    # attractive nuisance (it writes /opt and calls systemctl); drop it so it
    # cannot be invoked out of the package.
    rm -f $out/opt/mudfish/${finalAttrs.version}/bin/pkg_linux_setup.sh

    # mudstat is REMOVED rather than shipped broken. It is the only shipped
    # binary linking ncurses, and it requires the symbol-version nodes
    # NCURSES6_5.0.19991023 (from libncurses.so.6) *and*
    # NCURSES6_TINFO_5.0.19991023 (from libtinfo.so.6) simultaneously. nixpkgs
    # builds ncurses widec, so its libncurses.so.6 and libtinfo.so.6 are both
    # symlinks to libncursesw.so.6, which defines only the NCURSES6_TIC_* and
    # NCURSES6_TINFO_* nodes -- the plain NCURSES6_* node exists only in a
    # non-widec build. Satisfying both at once would mean dragging two separate
    # ncurses builds into the closure and merging them, for one auxiliary
    # statistics CLI that no other shipped binary execs (verified: the string
    # "mudstat" appears in no binary but mudstat itself) and that is not on the
    # daemon path. Equivalent status is available from the web UI and `mudadm`.
    # Removing it here, before fixupPhase, is also what lets ncurses drop out of
    # buildInputs entirely.
    rm -f $out/opt/mudfish/${finalAttrs.version}/bin/mudstat

    # var/ is created EMPTY and stays empty in the store. It cannot hold real
    # state -- the store is read-only, and the daemon writes pidfiles,
    # .snapshot.db (which is where the persisted JWT lives) and mudovpn.txt
    # there. It must nonetheless exist as a directory, because the unit
    # bind-mounts the writable StateDirectory over this exact path, and a bind
    # target nested inside a read-only bind cannot be conjured up at mount time.
    # Omitting this mkdir makes the unit fail during namespace setup, not later.
    mkdir -p $out/opt/mudfish/${finalAttrs.version}/var

    # Convenience entry points on PATH. These are symlinks into the same store
    # prefix, so argv[0] differs but the hardcoded /opt lookups still resolve
    # through the unit's bind mount.
    mkdir -p $out/bin
    for b in mudrun mudrun-headless mudadm mudmtr mudnetmon muddiag; do
      ln -s $out/opt/mudfish/${finalAttrs.version}/bin/$b $out/bin/$b
    done

    # Desktop integration for the tray GUI on the Hyprland session.
    install -Dm644 payload/share/mudrun.desktop $out/share/applications/mudrun.desktop
    install -Dm644 payload/share/mudrun_logo.png \
      $out/share/icons/hicolor/256x256/apps/mudrun.png

    runHook postInstall
  '';

  # The shipped .desktop points into /opt/..., which resolves only inside the
  # service's mount namespace; rewrite it to the store symlink so a desktop
  # launch works from a normal user session too.
  postFixup = ''
    substituteInPlace $out/share/applications/mudrun.desktop \
      --replace-quiet "/opt/mudfish/${finalAttrs.version}/bin/mudrun" "$out/bin/mudrun" \
      --replace-quiet "/opt/mudfish/${finalAttrs.version}/share/mudrun_logo.png" "mudrun"
  '';

  meta = {
    description = "Mudfish Cloud VPN client (route-optimising game VPN)";
    homepage = "https://mudfish.net/";
    # Closed-source vendor binary under Mudfish's own EULA; no SPDX-identifiable
    # licence ships in the archive.
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
    mainProgram = "mudrun-headless";
  };
})
