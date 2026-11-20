#!/bin/bash
# qdrant-railway: start wrapper for Qdrant on Railway.
#
# 1. Fails closed on weak API keys without failing the deploy (STANDARD 8.29):
#    - QDRANT__SERVICE__API_KEY empty or shorter than QDRANT_MIN_KEY_LENGTH: Qdrant starts with
#      a random key nobody knows (the API stays locked) and the log says how to fix it.
#    - QDRANT__SERVICE__READ_ONLY_API_KEY empty or too short: read-only access is switched off
#      (an empty read-only key would otherwise be a valid credential).
# 2. Creates the storage, snapshot and temp folders on the volume.
# 3. Hands over to Qdrant's own entrypoint (keeps its OOM recovery mode).
#
# No key value is ever printed.
set -u

log() { printf '[qdrant-railway] %s\n' "$*"; }

MIN_LENGTH="${QDRANT_MIN_KEY_LENGTH:-16}"
if ! [[ "${MIN_LENGTH}" =~ ^[0-9]{1,3}$ ]] || [ "${MIN_LENGTH}" -lt 8 ]; then
  log "WARNING: QDRANT_MIN_KEY_LENGTH='${MIN_LENGTH}' is not a whole number >= 8; using 16"
  MIN_LENGTH=16
fi

random_key() {
  head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48
}

api_key="${QDRANT__SERVICE__API_KEY:-}"
if [ "${#api_key}" -lt "${MIN_LENGTH}" ]; then
  QDRANT__SERVICE__API_KEY="$(random_key)"
  export QDRANT__SERVICE__API_KEY
  log "WARNING: QDRANT__SERVICE__API_KEY is empty or shorter than ${MIN_LENGTH} characters."
  log "WARNING: the API is locked with a random key nobody knows. Set QDRANT__SERVICE__API_KEY"
  log "WARNING: (${MIN_LENGTH}+ characters) on the Qdrant service and redeploy to use it."
fi

if [ -n "${QDRANT__SERVICE__READ_ONLY_API_KEY+set}" ]; then
  ro_key="${QDRANT__SERVICE__READ_ONLY_API_KEY}"
  if [ "${#ro_key}" -lt "${MIN_LENGTH}" ]; then
    unset QDRANT__SERVICE__READ_ONLY_API_KEY
    log "WARNING: QDRANT__SERVICE__READ_ONLY_API_KEY is empty or shorter than ${MIN_LENGTH} characters;"
    log "WARNING: read-only access is disabled until a longer key is set."
  elif [ "${ro_key}" = "${QDRANT__SERVICE__API_KEY}" ]; then
    log "WARNING: the read-only key equals the full API key; it grants full access."
  fi
fi

for dir_var in QDRANT__STORAGE__STORAGE_PATH QDRANT__STORAGE__SNAPSHOTS_PATH QDRANT__STORAGE__TEMP_PATH; do
  dir="${!dir_var:-}"
  if [ -n "${dir}" ]; then
    mkdir -p "${dir}" || log "WARNING: cannot create ${dir} (${dir_var})"
  fi
done

data_root="${QDRANT__STORAGE__STORAGE_PATH:-/qdrant/storage}"
if ! awk -v p="${RAILWAY_VOLUME_MOUNT_PATH:-/qdrant/data}" '$2 == p { found = 1 } END { exit !found }' /proc/mounts; then
  log "WARNING: no volume mounted at ${RAILWAY_VOLUME_MOUNT_PATH:-/qdrant/data}; collections are lost on redeploy."
fi
log "starting Qdrant (storage ${data_root}, snapshots ${QDRANT__STORAGE__SNAPSHOTS_PATH:-./snapshots})"

cd /qdrant || exit 1
exec ./entrypoint.sh "$@"
