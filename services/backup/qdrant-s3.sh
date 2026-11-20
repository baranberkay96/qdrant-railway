# qdrant-s3.sh: rclone remote "bucket" for the Railway Bucket that holds the backups.
# Sourced (POSIX sh) by qdrant-backup (backup, restore, list).
# The remote is configured only through the environment; nothing is written but an empty
# rclone.conf.
#
# Inputs: BACKUP_S3_BUCKET, BACKUP_S3_ENDPOINT, BACKUP_S3_ACCESS_KEY_ID,
#         BACKUP_S3_SECRET_ACCESS_KEY (required), BACKUP_S3_REGION (default auto),
#         BACKUP_S3_FORCE_PATH_STYLE (default false), BACKUP_PREFIX (default qdrant).
# Output: S3_REMOTE ("bucket:{bucket}/{prefix}"), S3_PREFIX; S3_ERROR on failure.

S3_RUN_RE='^[0-9]{8}T[0-9]{6}Z$'

s3_configure() {
  S3_ERROR=""
  s3_missing=""
  for s3_var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    eval "s3_val=\${${s3_var}:-}"
    [ -n "${s3_val}" ] || s3_missing="${s3_missing} ${s3_var}"
  done
  if [ -n "${s3_missing}" ]; then
    S3_ERROR="Bucket not configured (missing:${s3_missing})"
    return 1
  fi

  S3_PREFIX="${BACKUP_PREFIX:-qdrant}"
  if ! printf '%s\n' "${S3_PREFIX}" | grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' \
     || printf '/%s/\n' "${S3_PREFIX}" | grep -Eq '/\.{1,2}/'; then
    S3_ERROR="BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-' (no '.' or '..' segments), got '${S3_PREFIX}'"
    return 1
  fi
  case "${BACKUP_S3_FORCE_PATH_STYLE:-false}" in
    true|false) ;;
    *) S3_ERROR="BACKUP_S3_FORCE_PATH_STYLE must be true or false"; return 1 ;;
  esac

  RCLONE_CONFIG="${TMPDIR:-/tmp}/qdrant-backup-rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG
  # Railway Buckets use virtual-hosted-style URLs; path style only for buckets whose
  # Credentials tab says so.
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENV_AUTH=false
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  # 16 MiB parts: snapshots up to ~150 GiB (10,000 parts).
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  S3_REMOTE="bucket:${BACKUP_S3_BUCKET}/${S3_PREFIX}"
  return 0
}

# Folder names of every run (complete or not), oldest first. Other folders are ignored.
s3_list_runs() {
  rclone lsf --dirs-only "${S3_REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${S3_RUN_RE}" | sort || true
}

# Runs that finished: MANIFEST.txt is written last.
s3_list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${S3_REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${S3_RUN_RE}" | sort || true
}

# "{run} complete|incomplete" per line, oldest first.
s3_show_runs() {
  s3_complete=" $(s3_list_complete_runs | tr '\n' ' ')"
  s3_list_runs | while IFS= read -r s3_run; do
    [ -n "${s3_run}" ] || continue
    case "${s3_complete}" in
      *" ${s3_run} "*) printf '%s complete\n' "${s3_run}" ;;
      *) printf '%s incomplete\n' "${s3_run}" ;;
    esac
  done
}

# Drop the remote's credentials from the environment (before exec'ing the server).
s3_forget() {
  unset RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY \
        RCLONE_CONFIG_BUCKET_TYPE RCLONE_CONFIG_BUCKET_PROVIDER RCLONE_CONFIG_BUCKET_ENV_AUTH \
        RCLONE_CONFIG_BUCKET_ENDPOINT RCLONE_CONFIG_BUCKET_REGION RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE \
        RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET RCLONE_CONFIG_BUCKET_CHUNK_SIZE RCLONE_CONFIG
}
