{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # MODEL STORE (OUTSIDE THE NIX STORE, DELIBERATELY)
  # ---------------------------------------------------------------------------
  # Weights are ~20 GiB of opaque third-party binary with no reproducible build.
  # Fetching them with a fixed-output derivation would copy all of it into
  # /nix/store and make every system generation that references it a GC root, so
  # a handful of rebuilds would pin a hundred gigabytes. /var/lib is the FHS home
  # for exactly this shape of state: mutable, service-owned, survives rebuilds,
  # and `nix-collect-garbage` never looks at it.
  modelDir = "/var/lib/llama/models";

  # Filename as published by the source repo -- see the download command in the
  # service comment below. Changing quant means changing this line and nothing
  # else.
  modelFile = "${modelDir}/Huihui-Qwen3.6-35B-A3B-abliterated.Q4_K_M.gguf";

  # ---------------------------------------------------------------------------
  # BACKEND: VULKAN / RADV, NOT ROCm
  # ---------------------------------------------------------------------------
  # This APU is gfx1150 (Strix Point, RDNA 3.5). ROCm is not used here and that
  # is a decision, not an omission: gfx1150 is not in the default HSA target
  # list rocmPackages builds, and the usual workaround -- pointing
  # HSA_OVERRIDE_GFX_VERSION at 11.0.0 or 11.0.3 -- runs code objects compiled
  # for gfx1100/gfx1103 on silicon they were not built for, which is how you get
  # wrong numerics that look like a working model.
  #
  # RADV needs no such lie. It compiles SPIR-V for the device actually present,
  # and the Mesa this system runs (26.x via chaotic.mesa-git) advertises
  # VK_KHR_cooperative_matrix on this part, so the matmul kernels hit the WMMA
  # path rather than scalar fallback.
  #
  # The override is cheap: nixpkgs' llama-cpp gates the whole Vulkan backend on
  # this one flag, and the result is already in the binary cache.
  llamaCppVulkan = pkgs.llama-cpp.override {vulkanSupport = true;};

  # ---------------------------------------------------------------------------
  # SERVING PARAMETERS
  # ---------------------------------------------------------------------------
  # KV cache is q8_0 on both K and V. That halves it against the f16 default for
  # a quality cost that does not show up in practice, and on this machine the KV
  # cache is the only part of the resident footprint that is cheap to shrink --
  # the weights are the weights.
  #
  # If llama-server dies during startup with a Vulkan allocation failure, this
  # is the number to cut (16384 first). Do NOT reach for the GTT kernel params
  # instead: they are already sized to nearly all of usable RAM.
  contextSize = 32768;

  # Loopback only. This server has no authentication of any kind and will answer
  # anything that can reach the socket; it must not be bound to a routable
  # address without something in front of it.
  listenAddress = "127.0.0.1";
  listenPort = 8080;
in {
  # ---------------------------------------------------------------------------
  # PACKAGES
  # ---------------------------------------------------------------------------
  environment.systemPackages = [
    llamaCppVulkan

    # Provides both `hf` and the deprecated `huggingface-cli` alias. Used to
    # populate modelDir by hand -- see the service comment for the invocation.
    pkgs.python3Packages.huggingface-hub
  ];

  # ---------------------------------------------------------------------------
  # MODEL DIRECTORY
  # ---------------------------------------------------------------------------
  # Owned by the login user rather than root: the server below is a *user* unit,
  # and the weights are fetched interactively with `hf download`. Nothing here
  # runs privileged, so there is no reason for the store to be root-only.
  systemd.tmpfiles.rules = [
    "d /var/lib/llama 0755 crazycat users - -"
    "d ${modelDir} 0755 crazycat users - -"
  ];

  # ---------------------------------------------------------------------------
  # llama-server (USER UNIT, MANUAL START)
  # ---------------------------------------------------------------------------
  # Deliberately NOT `wantedBy = ["default.target"]`. Starting this on every
  # login would fault ~20 GiB of weights into a 30 GiB machine before the
  # desktop has finished coming up, on a laptop whose whole configuration is
  # tuned around not stalling. Opt in per boot:
  #
  #     systemctl --user start llama-server
  #     systemctl --user enable --now llama-server   # if you do want it always
  #
  # Populate the model store first (fish):
  #
  #     hf download mradermacher/Huihui-Qwen3.6-35B-A3B-abliterated-GGUF \
  #       Huihui-Qwen3.6-35B-A3B-abliterated.Q4_K_M.gguf \
  #       --local-dir /var/lib/llama/models
  #
  # SPECULATIVE DECODING IS ABSENT ON PURPOSE -- see below. The flags would be
  #     --spec-type draft-mtp --spec-draft-n-max 6
  # and llama.cpp 0.4.0 (the version nixpkgs ships here) implements them fully:
  # `draft-mtp` is a live entry in common_speculative_type_from_name_map, and
  # this model's architecture, qwen35moe, is one of the cases its driver names
  # explicitly. The blocker is the weights, not the runtime.
  #
  # common_speculative_impl_draft_mtp asserts `ctx_tgt && ctx_dft`: the MTP head
  # has to arrive as its own GGUF, loaded as a draft model. llama.cpp will even
  # fetch it for you -- common_download_get_hf_plan picks "the best sibling GGUF
  # whose filename contains `mtp`" when --spec-type draft-mtp is set -- but no
  # such sibling is published. huihui-ai's own *-MTP-GGUF repo ships seven
  # whole-model quants, an mmproj, and nothing else; the "MTP" in its name
  # describes the upstream architecture, not a file. Same for the other Qwen3.6
  # GGUF repos checked.
  #
  # So: if an MTP sidecar shows up, add the two flags plus
  #     --spec-draft-model <path-to-mtp.gguf>
  # and the assert will be satisfied. Until then the flags would abort at
  # startup, and quietly dropping them would hide a real capability gap.
  systemd.user.services.llama-server = {
    description = "llama.cpp inference server (Vulkan/RADV, loopback only)";
    documentation = ["https://github.com/ggml-org/llama.cpp"];

    serviceConfig = {
      Type = "exec";
      ExecStart = lib.escapeShellArgs [
        "${llamaCppVulkan}/bin/llama-server"
        "--model"
        modelFile
        "--host"
        listenAddress
        "--port"
        (toString listenPort)

        # Offload everything. 99 is the idiom for "all layers"; the model has
        # far fewer, and llama.cpp clamps.
        "--n-gpu-layers"
        "99"

        # Explicit `on`, not `auto`. On a build where flash attention silently
        # declined to engage, the KV cache quantization below would be the thing
        # that broke, and it would break as a slow leak of memory rather than as
        # an error. Fail loudly instead.
        "--flash-attn"
        "on"
        "--ctx-size"
        (toString contextSize)
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
      ];

      # A 20 GiB model takes a long time to fault in from NVMe on a cold cache;
      # systemd's default 90 s start timeout will kill it mid-load.
      TimeoutStartSec = "10min";

      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
