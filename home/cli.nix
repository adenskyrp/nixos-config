# Shell, git, ssh and command-line tools.
{pkgs, ...}: {
  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
  };
  programs.git = {
    enable = true;
    settings.user = {
      name = "adenskyrp";
      email = "36445815+adenskyrp@users.noreply.github.com";
    };
  };

  programs.fish = {
    enable = true;
    functions = {
      sysdeploy = ''
        set -l current_dir $PWD
        cd ~/nixos-config
        git add .

        set -l target_host (hostname)
        echo "--> Initiating declarative system rebuild for host: $target_host..."
        if sudo nixos-rebuild switch --no-write-lock-file --flake .#$target_host
          set -l commit_msg "$argv"
          if test -z "$commit_msg"
            set commit_msg "chore($target_host): automated system state update"
          end
          git commit -m "$commit_msg"
          echo "--> Pushing new generation to GitHub..."
          git push origin main
          echo "--> System successfully deployed and tracked."
        else
          echo "--> Build failed. Git commit aborted. Fix your Nix syntax."
        end

        cd $current_dir
      '';
    };
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        ServerAliveInterval = 30;
        ServerAliveCountMax = 3;
        TCPKeepAlive = "yes";
      };
    };
  };

  home.packages = with pkgs; [
    claude-code
    google-cloud-sdk
    docker-client
    aria2
    libva-utils
    p7zip
    unzip
    unrar
    zip

    # Bumps modules/proton-cachyos.json to the latest release.
    (writeShellApplication {
      name = "update-proton-cachyos";
      runtimeInputs = [curl jq nix];
      text = ''
         set -euo pipefail

         # Point directly to the new modules folder
         CONFIG_DIR="/home/crazycat/nixos-config"
         JSON_FILE="$CONFIG_DIR/modules/proton-cachyos.json"

         echo "Fetching latest Proton-CachyOS release metadata..."
         RELEASE_JSON=$(curl -sSL "https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest")
         VERSION=$(echo "$RELEASE_JSON" | jq -r .tag_name)

         # Ensure we specifically grab the x86_64_v3 SLR package
        ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name | test("slr-x86_64_v3\\.tar\\.xz$")) | .browser_download_url')

         if [ -f "$JSON_FILE" ]; then
           CURRENT_VERSION=$(jq -r .version "$JSON_FILE")
           if [ "$CURRENT_VERSION" = "$VERSION" ]; then
             echo "Already up-to-date: $VERSION"
             exit 0
           fi
         fi

         echo "New version found: $VERSION"
         echo "Prefetching SRI hash..."
         HASH=$(nix store prefetch-file "$ASSET_URL" --json | jq -r .hash)

         jq -n \
           --arg version "$VERSION" \
           --arg url "$ASSET_URL" \
           --arg hash "$HASH" \
           '{version: $version, url: $url, hash: $hash}' > "$JSON_FILE"

         echo "Updated $JSON_FILE to $VERSION ($HASH)"
      '';
    })
  ];
}
