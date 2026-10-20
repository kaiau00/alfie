#!/bin/bash
# livekit-wakeword <stage> for hey-moe.yaml, with the espeak-ng shim on PATH.
set -u
W=/path/to/wake
export PATH="$W/bin:$PATH"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export HF_HUB_DISABLE_XET=1
export SSL_CERT_FILE="$W/ca-bundle.pem" REQUESTS_CA_BUNDLE="$W/ca-bundle.pem" CURL_CA_BUNDLE="$W/ca-bundle.pem"
cd "$W/train"
stage="$1"; shift
case "$stage" in
  setup) "$W/venv/bin/livekit-wakeword" setup --config hey-moe.yaml "$@" ;;
  py)    "$W/venv/bin/python" "$@" ;;
  *)     "$W/venv/bin/livekit-wakeword" "$stage" hey-moe.yaml "$@" ;;
esac
rc=$?
echo "exit=$rc"
exit $rc
