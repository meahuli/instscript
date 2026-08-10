#!/usr/bin/env bash
# ============================================================
# MiniMax-H3 video+audio — INT8 ConvRot weights + official workflows.
# Source workflows (Comfy-Org/workflow_templates):
#   video_minimax_h3_t2v.json  (fl2va)
#   video_minimax_h3_i2v.json  (fl2va — first frame / last frame / both)
#   video_minimax_h3_r2v.json  (ref2va — reference identity, style, voice)
#
# Run:  bash /workspace/instscript/dl-minimax-h3.sh                # fl2va -> T2V + I2V
#       MODELS=ref2va bash /workspace/instscript/dl-minimax-h3.sh  # ref2va -> R2V
#       PRUNED=0 bash /workspace/instscript/dl-minimax-h3.sh       # full 34 GB convrot
#       ENCODER=stock bash /workspace/instscript/dl-minimax-h3.sh  # censored Comfy-Org encoder
#       WITH_TAIL=1 bash /workspace/instscript/dl-minimax-h3.sh    # + tail + enhancer workflow
#
# Everything quantized is INT8 ConvRot (the VAEs ship fp16/fp32 only — no
# convrot build exists). Default text encoder is the uncensored Ultra Heretic
# Qwen3-VL-32B build, which the workflows are patched to use.
#
#   MODELS=fl2va (DEFAULT) — T2V + I2V (text, first frame, last frame, or both).
#   MODELS=ref2va          — R2V (reference identity / style / voice).
#     One checkpoint per run — they are 21 GB each and separate networks, not a
#     LoRA pair. Re-run with the other value to add it; nothing is deleted for you.
#   PRUNED=1    (DEFAULT) — *_pruned_int8_convrot, 21 GB, what the official
#                           workflows ship with.
#   PRUNED=0              — *_int8_convrot, 34 GB, unpruned.
#   ENCODER=uncensored (DEFAULT) — ethanfel Ultra Heretic H3 INT8 ConvRot, 26 GB.
#   ENCODER=stock                — Comfy-Org qwen3vl_32b_minimax_h3 INT8 ConvRot, 27 GB.
#   WITH_TAIL=0 (DEFAULT)  — no tail. T2V/I2V/R2V do not use it; the tail only feeds
#                            the prompt enhancer, never the video model.
#   WITH_TAIL=1            — + layers 50-63 tail (7.6 GB) and, on MODELS=fl2va, an
#                            enhancer workflow. Needs custom node ComfyUI-MiniMax-H3-Guide
#                            (pinned in provision.sh NODES) or its two nodes go red.
#
# Default download ~53 GB. Needs 32 GB VRAM (the encoder peaks near 26 GiB), a
# ComfyUI new enough to have native MiniMax-H3 nodes, and comfy-kitchen for the
# ConvRot INT8 kernels.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-lib.sh"

MODELS_SEL="${MODELS:-fl2va}"
PRUNED="${PRUNED:-1}"
ENCODER="${ENCODER:-uncensored}"
WITH_TAIL="${WITH_TAIL:-0}"

case "$MODELS_SEL" in fl2va|ref2va) ;; *) echo "ERROR: MODELS must be fl2va or ref2va, one per run (got '$MODELS_SEL')" >&2; exit 1 ;; esac
case "$PRUNED"    in 0|1) ;;           *) echo "ERROR: PRUNED must be 0 or 1 (got '$PRUNED')" >&2; exit 1 ;; esac
case "$WITH_TAIL" in 0|1) ;;           *) echo "ERROR: WITH_TAIL must be 0 or 1 (got '$WITH_TAIL')" >&2; exit 1 ;; esac
[ "$MODELS_SEL" = "fl2va" ] && OTHER="ref2va" || OTHER="fl2va"

MM="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
EF="https://huggingface.co/ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot/resolve/main"
WFBASE="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates"
WF_DIR="$COMFY/user/default/workflows"
TAIL_FILE="qwen3vl_32b_h3_generation_tail_50_63_int8_convrot.safetensors"
TAIL_URL="$EF/$TAIL_FILE"
# Enhancer workflow = the official i2v template with the tail chain added (verified:
# same subgraph uuid, same node ids). Pinned to a commit — an unpinned raw URL means
# whatever lands on their default branch, including the properties.models URLs that
# ComfyUI-AutoModelDownloader will fetch from.
ENH_WF="https://raw.githubusercontent.com/MasterToycode/Comfyui_local_minimax_h3_hen/8234ac802c2fb43d039a1f3582811f618970fc06/minimax_h3_enhancer.json"
ENH_NAME="video_minimax_h3_i2v_enhancer.json"

# Pruned is the workflows' default; unpruned keeps the layers they drop.
if [ "$PRUNED" = "1" ]; then VARIANT="pruned_int8_convrot"; else VARIANT="int8_convrot"; fi

# Encoder: layers 0-49 conditioning checkpoint. H3 reads the hidden state after
# layer 49, so the uncensored edits (Heretic ARA, layers 31-40) are all in range.
case "$ENCODER" in
  uncensored) ENC_FILE="qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors"
              ENC_URL="$EF/$ENC_FILE" ;;
  stock)      ENC_FILE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
              ENC_URL="$MM/text_encoders/$ENC_FILE" ;;
  *) echo "ERROR: ENCODER must be uncensored or stock (got '$ENCODER')" >&2; exit 1 ;;
esac

# Free-space advisory — this volume fills fast and aria2c dies mid-file when it does.
NEED=$([ "$PRUNED" = "1" ] && echo 21 || echo 34)
NEED=$((NEED + 27 + 6))                       # + encoder + both VAEs
[ "$WITH_TAIL" = "1" ] && NEED=$((NEED + 8))
FREE=$(df -BG --output=avail "$MODELS_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
echo "==> $MODELS_SEL selected; ~${NEED} GB to download; ${FREE:-?} GB free on $MODELS_DIR"
if [ -n "$FREE" ] && [ "$FREE" -lt "$NEED" ]; then
  echo "    WARNING: not enough free space — clear old models first or downloads will truncate."
fi

# The other checkpoint is 21 GB of dead weight if you are not switching back to it.
# Reported, not deleted — losing it means re-downloading 21 GB.
OTHER_ON_DISK=$(ls -1 "$MODELS_DIR/diffusion_models/minimax_h3_${OTHER}"*.safetensors 2>/dev/null)
if [ -n "$OTHER_ON_DISK" ]; then
  echo "==> $OTHER already on disk and unused by this run — reclaim its space with:"
  printf '      rm %s\n' $OTHER_ON_DISK
fi

# 1) diffusion model — one per run. fl2va = T2V/I2V (text, first frame, last frame,
#    or both); ref2va = R2V (reference identity/style/voice). Separate networks.
get "$MM/diffusion_models/minimax_h3_${MODELS_SEL}_${VARIANT}.safetensors" diffusion_models "minimax_h3_${MODELS_SEL}_${VARIANT}.safetensors"

# 2) text encoder -> text_encoders/ FLAT (the repo card says H3/, but flat keeps
#    ComfyUI-AutoModelDownloader able to fetch it — it rejects any path separator).
get "$ENC_URL" text_encoders "$ENC_FILE"

# 3) optional layers 50-63 tail: prompt enhancement / standalone text gen only,
#    not needed to render. Uncensored source family, matching the default encoder.
if [ "$WITH_TAIL" = "1" ]; then
  get "$TAIL_URL" text_encoders "$TAIL_FILE"
else
  echo "==> skipping optional generation tail + enhancer workflow (set WITH_TAIL=1 for both)"
fi

# 4) VAEs — video + audio, both required by every workflow. fp16/fp32 only.
get "$MM/vae/minimax_h3_video_vae_fp16.safetensors" vae minimax_h3_video_vae_fp16.safetensors
get "$MM/vae/minimax_h3_audio_vae_fp32.safetensors" vae minimax_h3_audio_vae_fp32.safetensors

# 5) workflow JSONs -> Workflows sidebar, patched to the files downloaded above.
#    The templates hardcode the nvfp4_awq encoder and the pruned checkpoints, in
#    both the loader widget and properties.models (which drives auto-download).
#    Only the workflows the selected checkpoint can actually run are installed.
case "$MODELS_SEL" in
  fl2va)  WFS="video_minimax_h3_t2v.json video_minimax_h3_i2v.json" ;;
  ref2va) WFS="video_minimax_h3_r2v.json" ;;
esac
mkdir -p "$WF_DIR"
for WF_NAME in $WFS; do
  echo "==> workflows/$WF_NAME"
  aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" "$WFBASE/$WF_NAME" \
    || { echo "  workflow download failed: $WF_NAME — fetch it manually from the templates repo."; continue; }
  WF="$WF_DIR/$WF_NAME"
  # encoder: filename first (it also rewrites the tail of the metadata URL), then the repo prefix
  sed -i "s|qwen3vl_32b_minimax_h3_nvfp4_awq\.safetensors|$ENC_FILE|g" "$WF"
  sed -i "s|$MM/text_encoders/$ENC_FILE|$ENC_URL|g" "$WF"
  # checkpoint: only diverges from the template when PRUNED=0
  [ "$PRUNED" = "0" ] && sed -i "s|_pruned_int8_convrot|_int8_convrot|g" "$WF"
  echo "    patched -> $ENC_FILE + minimax_h3_*_${VARIANT}.safetensors"
done

# 6) enhancer workflow — only useful with the tail, and it is an fl2va (i2v) graph.
#    Needs custom nodes MiniMaxH3GenerationTailLoader + MiniMaxH3PromptEnhancer from
#    ethanfel/ComfyUI-MiniMax-H3-Guide (pinned in provision.sh NODES).
if [ "$WITH_TAIL" = "1" ] && [ "$MODELS_SEL" = "fl2va" ]; then
  echo "==> workflows/$ENH_NAME"
  if aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$ENH_NAME" "$ENH_WF"; then
    WF="$WF_DIR/$ENH_NAME"
    # It hardcodes the uncensored encoder, so this is a no-op unless ENCODER=stock.
    sed -i "s|qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot\.safetensors|$ENC_FILE|g" "$WF"
    [ "$PRUNED" = "0" ] && sed -i "s|_pruned_int8_convrot|_int8_convrot|g" "$WF"
    # Its CLIPLoader and tail loader ship with no properties.models, so auto-download
    # cannot resolve the two biggest files. Inject it. NOTE: "S&R" means the '&' has to
    # be escaped in the replacement, or sed substitutes the whole match back in.
    sed -i "s|\"Node name for S&R\": \"CLIPLoader\"|\"Node name for S\\&R\": \"CLIPLoader\", \"models\": [{\"name\": \"$ENC_FILE\", \"url\": \"$ENC_URL\", \"directory\": \"text_encoders\"}]|" "$WF"
    sed -i "s|\"Node name for S&R\": \"MiniMaxH3GenerationTailLoader\"|\"Node name for S\\&R\": \"MiniMaxH3GenerationTailLoader\", \"models\": [{\"name\": \"$TAIL_FILE\", \"url\": \"$TAIL_URL\", \"directory\": \"text_encoders\"}]|" "$WF"
    echo "    patched -> $ENC_FILE + $TAIL_FILE, auto-download metadata added"
    echo "    needs custom node: ethanfel/ComfyUI-MiniMax-H3-Guide"
  else
    echo "  enhancer workflow download failed — re-run this script to retry."
  fi
elif [ "$WITH_TAIL" = "1" ]; then
  echo "==> skipping enhancer workflow: it is an fl2va graph and MODELS=$MODELS_SEL"
fi

# Native MiniMax-H3 support landed recently; an older checkout red-nodes the whole graph.
if ! grep -rqil minimax "$COMFY/comfy_extras" "$COMFY/comfy/ldm" 2>/dev/null; then
  echo ""
  echo "WARNING: no MiniMax code found in this ComfyUI checkout — update it, or the"
  echo "         MiniMaxH3ImageToVideo / CLIPLoader 'minimax' type will show as missing."
fi

echo ""
echo "MiniMax-H3 ready in $MODELS_DIR"
echo "  checkpoint: minimax_h3_${MODELS_SEL}_${VARIANT}.safetensors"
echo "  encoder:    $ENC_FILE"
echo "  workflows:  $WF_DIR"
echo "  to add $OTHER later:  MODELS=$OTHER bash $0"
echo "INT8 ConvRot needs comfy-kitchen installed in the ComfyUI venv (CUDA 13.0+ build"
echo "for the fast kernels; CUDA 12.8 works via fallback ops, just slower)."
