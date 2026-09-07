#!/usr/bin/env bash
# Fetches the MobileCLIP weights the semantic search needs.
#
# They are NOT part of this repository and must not be committed. Apple
# releases MobileCLIP's weights under a licence limited to research purposes,
# which excludes product development and any commercial use — see
# https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS. Fetching
# them here is for personal, local use; do not redistribute the result.
#
# The CLIP vocabulary and merge list are OpenAI's, under the MIT licence.
set -euo pipefail

DEST="${LUMEN_MODELS:-$HOME/Library/Application Support/cc.lumen.Lumen/Models}"
mkdir -p "$DEST"

clip="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
for pkg in mobileclip_s0_image mobileclip_s0_text; do
    if [ -f "$DEST/$pkg.mlpackage/Data/com.apple.CoreML/weights/weight.bin" ]; then
        echo "==> $pkg already present"
        continue
    fi
    echo "==> Fetching $pkg"
    mkdir -p "$DEST/$pkg.mlpackage/Data/com.apple.CoreML/weights"
    for f in "Manifest.json" \
             "Data/com.apple.CoreML/model.mlmodel" \
             "Data/com.apple.CoreML/weights/weight.bin"; do
        curl -fL --progress-bar "$clip/$pkg.mlpackage/$f" -o "$DEST/$pkg.mlpackage/$f"
    done
done

tokenizer="https://huggingface.co/openai/clip-vit-base-patch32/resolve/main"
[ -f "$DEST/clip_vocab.json" ]  || curl -fL --progress-bar "$tokenizer/vocab.json"  -o "$DEST/clip_vocab.json"
[ -f "$DEST/clip_merges.txt" ]  || curl -fL --progress-bar "$tokenizer/merges.txt"  -o "$DEST/clip_merges.txt"

echo "==> Installed into $DEST"
echo "    Open Folders and press Build Index to embed the library."
