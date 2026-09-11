#!/bin/sh
# One-time setup: Python env, Wav2Lip source (vendored, NOT redistributed), model weights.
# Wav2Lip is licensed for personal / research / non-commercial use only — see its repository.
set -e
cd "$(dirname "$0")"
uv sync
mkdir -p vendor weights
[ -d vendor/Wav2Lip ] || git clone --depth 1 https://github.com/Rudrabha/Wav2Lip vendor/Wav2Lip
dl() { [ -s "$2" ] || curl -L --progress-bar -o "$2" "$1"; }
dl https://huggingface.co/camenduru/Wav2Lip/resolve/main/checkpoints/wav2lip_gan.pth weights/wav2lip_gan.pth
dl https://huggingface.co/camenduru/Wav2Lip/resolve/main/face_detection/detection/sfd/s3fd.pth vendor/Wav2Lip/face_detection/detection/sfd/s3fd.pth
echo "sidecar ready: run 'make sidecar'"
