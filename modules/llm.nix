{
  config,
  pkgs,
  lib,
  ...
}: let
  # ---------------------------------------------------------------------------
  # MODEL STORE (OUTSIDE THE NIX STORE, DELIBERATELY)
  # ---------------------------------------------------------------------------
  modelDir = "/var/lib/llama/models";

  # Expert-Granular Abliteration (EGA) build of Gemma 4 26B-A4B (3.8B active).
  # Alternatives:
  #   "gemma-4-26B-A4B-it-ultra-uncensored-heretic-Q4_K_M.gguf" (llmfan46)
  #   "Huihui-gemma-4-26B-A4B-it-abliterated.Q4_K_M.gguf"       (mradermacher)
  modelFile = "${modelDir}/gemma-4-26B-A4B-it-uncensored-Q4_K_M.gguf";

  # ---------------------------------------------------------------------------
  # BACKEND: VULKAN / RADV, NOT ROCm (gfx1150 WMMA via VK_KHR_cooperative_matrix)
  # ---------------------------------------------------------------------------
  llamaCppVulkan = pkgs.llama-cpp.override {vulkanSupport = true;};

  # ---------------------------------------------------------------------------
  # SERVING PARAMETERS
  # ---------------------------------------------------------------------------
  # Gemma 4 26B-A4B uses hybrid 1024-token sliding-window local layers + unified
  # K/V p-RoPE global layers, making 32768 (or even 65536) at q8_0 dramatically
  # lighter on GTT than pure full-attention models.
  contextSize = 32768;

  # ---------------------------------------------------------------------------
  # MEMORY BUDGET -- DO NOT RUN THIS AND A GAME AT THE SAME TIME
  # ---------------------------------------------------------------------------
  # On 30.65 GiB of usable LPDDR5X-7500 RAM:
  #
  #   GTT ceiling      24.00 GiB   (ttm.pages_limit, hosts/omnibook)
  #   zram swap       ~15.30 GiB   (core.nix, zramSwap.memoryPercent = 50)
  #   model weights   ~15.60 GiB   (Gemma 4 26B-A4B Q4_K_M, down from 19.71 GiB)
  #
  # With q8_0 KV cache + compute buffers, total GTT residency sits around
  # ~17.0-17.5 GiB, leaving ~6.5 GiB of breathing room under the 24 GiB GTT cap.
  # Still: `systemctl --user stop llama-server` before launching Deadlock.

  listenAddress = "127.0.0.1";
  listenPort = 8080;
in {
  environment.systemPackages = [
    llamaCppVulkan
    pkgs.jq
    pkgs.python3Packages.huggingface-hub
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/llama 0755 crazycat users - -"
    "d ${modelDir} 0755 crazycat users - -"
  ];

  # ---------------------------------------------------------------------------
  # llama-server (USER UNIT, MANUAL START)
  # ---------------------------------------------------------------------------
  # Populate the model store first (fish):
  #
  #   # Option 1: TrevorJS (Expert-Granular Abliteration for MoE)
  #   hf download TrevorJS/gemma-4-26B-A4B-it-uncensored-GGUF \
  #     gemma-4-26B-A4B-it-uncensored-Q4_K_M.gguf \
  #     --local-dir /var/lib/llama/models
  #
  #   # Option 2: llmfan46 Heretic v1.2.0 (Arbitrary-Rank Ablation)
  #   hf download llmfan46/gemma-4-26B-A4B-it-ultra-uncensored-heretic-GGUF \
  #     gemma-4-26B-A4B-it-ultra-uncensored-heretic-Q4_K_M.gguf \
  #     --local-dir /var/lib/llama/models
  #
  #   # Option 3: mradermacher / Huihui-AI
  #   hf download mradermacher/Huihui-gemma-4-26B-A4B-it-abliterated-GGUF \
  #     Huihui-gemma-4-26B-A4B-it-abliterated.Q4_K_M.gguf \
  #     --local-dir /var/lib/llama/models
  systemd.user.services.llama-server = {
    description = "llama.cpp inference server (Gemma 4 26B-A4B, Vulkan/RADV, loopback only)";
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
        "--n-gpu-layers"
        "99"
        "--flash-attn"
        "on"
        "--ctx-size"
        (toString contextSize)
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        # Google's recommended sampling envelope for Gemma 4 26B-A4B
        "--temp"
        "1.0"
        "--top-p"
        "0.95"
        "--top-k"
        "64"
      ];

      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
