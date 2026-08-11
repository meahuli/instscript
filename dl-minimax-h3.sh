#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/model-lib.sh"

MODELS_SEL="${MODELS:-fl2va}"
PRUNED="${PRUNED:-1}"
ENCODER="${ENCODER:-uncensored}"
WITH_TAIL="${WITH_TAIL:-1}"

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
ENH_WF="https://raw.githubusercontent.com/MasterToycode/Comfyui_local_minimax_h3_hen/8234ac802c2fb43d039a1f3582811f618970fc06/minimax_h3_enhancer.json"
ENH_NAME="video_minimax_h3_i2v_enhancer.json"

if [ "$PRUNED" = "1" ]; then VARIANT="pruned_int8_convrot"; else VARIANT="int8_convrot"; fi

case "$ENCODER" in
  uncensored) ENC_FILE="qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors"
              ENC_URL="$EF/$ENC_FILE" ;;
  stock)      ENC_FILE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
              ENC_URL="$MM/text_encoders/$ENC_FILE" ;;
  *) echo "ERROR: ENCODER must be uncensored or stock (got '$ENCODER')" >&2; exit 1 ;;
esac

NEED=$([ "$PRUNED" = "1" ] && echo 21 || echo 34)
NEED=$((NEED + 27 + 6))
[ "$WITH_TAIL" = "1" ] && NEED=$((NEED + 8))
FREE=$(df -BG --output=avail "$MODELS_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
echo "==> $MODELS_SEL selected; ~${NEED} GB to download; ${FREE:-?} GB free on $MODELS_DIR"
if [ -n "$FREE" ] && [ "$FREE" -lt "$NEED" ]; then
  echo "    WARNING: not enough free space — clear old models first or downloads will truncate."
fi

OTHER_ON_DISK=$(ls -1 "$MODELS_DIR/diffusion_models/minimax_h3_${OTHER}"*.safetensors 2>/dev/null)
if [ -n "$OTHER_ON_DISK" ]; then
  echo "==> $OTHER already on disk and unused by this run — reclaim its space with:"
  printf '      rm %s\n' $OTHER_ON_DISK
fi

get "$MM/diffusion_models/minimax_h3_${MODELS_SEL}_${VARIANT}.safetensors" diffusion_models "minimax_h3_${MODELS_SEL}_${VARIANT}.safetensors"

get "$ENC_URL" text_encoders "$ENC_FILE"

if [ "$WITH_TAIL" = "1" ]; then
  get "$TAIL_URL" text_encoders "$TAIL_FILE"
else
  echo "==> skipping generation tail + enhancer workflow (WITH_TAIL=0)"
fi

get "$MM/vae/minimax_h3_video_vae_fp16.safetensors" vae minimax_h3_video_vae_fp16.safetensors
get "$MM/vae/minimax_h3_audio_vae_fp32.safetensors" vae minimax_h3_audio_vae_fp32.safetensors

case "$MODELS_SEL" in
  fl2va)  WFS="video_minimax_h3_t2v.json video_minimax_h3_i2v.json" ;;
  ref2va) WFS="video_minimax_h3_r2v.json" ;;
esac
[ "$WITH_TAIL" = "1" ] && [ "$MODELS_SEL" = "fl2va" ] && WFS="$WFS $ENH_NAME"
[ "$WITH_TAIL" = "1" ] && [ "$MODELS_SEL" = "ref2va" ] && \
  echo "==> no enhancer workflow: it is an fl2va graph and MODELS=ref2va"

deploy_local() {
  [ -f "$SELF_DIR/$1" ] || return 1
  cp "$SELF_DIR/$1" "$WF_DIR/$1" || return 1
  echo "    from $SELF_DIR (RAM-only preview/input nodes)"
  return 0
}

mkdir -p "$WF_DIR"
for WF_NAME in $WFS; do
  echo "==> workflows/$WF_NAME"
  if deploy_local "$WF_NAME"; then
    LOCAL=1
  else
    LOCAL=0
    SRC="$WFBASE/$WF_NAME"; [ "$WF_NAME" = "$ENH_NAME" ] && SRC="$ENH_WF"
    aria2c $ARIA_OPTS --dir="$WF_DIR" --out="$WF_NAME" "$SRC" \
      || { echo "  download failed: $WF_NAME — re-run to retry."; continue; }
    echo "    downloaded (stock SaveVideo/LoadImage nodes)"
  fi
  WF="$WF_DIR/$WF_NAME"

  sed -i "s|qwen3vl_32b_minimax_h3_nvfp4_awq\.safetensors|$ENC_FILE|g" "$WF"
  sed -i "s|qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot\.safetensors|$ENC_FILE|g" "$WF"
  sed -i "s|$MM/text_encoders/$ENC_FILE|$ENC_URL|g" "$WF"
  sed -i "s|$EF/$ENC_FILE|$ENC_URL|g" "$WF"
  [ "$PRUNED" = "0" ] && sed -i "s|_pruned_int8_convrot|_int8_convrot|g" "$WF"

  if [ "$LOCAL" = "0" ] && [ "$WF_NAME" = "$ENH_NAME" ]; then
    sed -i "s|\"Node name for S&R\": \"CLIPLoader\"|\"Node name for S\\&R\": \"CLIPLoader\", \"models\": [{\"name\": \"$ENC_FILE\", \"url\": \"$ENC_URL\", \"directory\": \"text_encoders\"}]|" "$WF"
    sed -i "s|\"Node name for S&R\": \"MiniMaxH3GenerationTailLoader\"|\"Node name for S\\&R\": \"MiniMaxH3GenerationTailLoader\", \"models\": [{\"name\": \"$TAIL_FILE\", \"url\": \"$TAIL_URL\", \"directory\": \"text_encoders\"}]|" "$WF"
    echo "    injected auto-download metadata for the encoder + tail"
  fi
  [ "$WF_NAME" = "$ENH_NAME" ] && echo "    needs custom node: ethanfel/ComfyUI-MiniMax-H3-Guide"
done

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
