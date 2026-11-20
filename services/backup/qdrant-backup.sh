#!/bin/bash
# qdrant-backup: Qdrant collection snapshots in a Railway Bucket, with retention and restore.
# Runs once and exits: the "Qdrant Backup" service is a Railway cron job.
#
#   qdrant-backup            restore first if QDRANT_RESTORE_FROM names a run not restored yet,
#                            then back up (the default)
#   qdrant-backup backup     back up only
#   qdrant-backup list       list the runs stored in the Bucket
#
# Backup: for every collection, Qdrant writes a snapshot (POST /collections/{c}/snapshots),
# the job streams it from the Qdrant API straight into the Bucket (no local copy), checks the
# uploaded size against the size Qdrant reported, records Qdrant's SHA-256 and deletes the
# snapshot from the Qdrant volume. Aliases are saved as aliases.json.
#
# Layout in the Bucket (one folder per run, UTC time):
#   {BACKUP_PREFIX}/20261120T031500Z/0001.snapshot   one file per collection
#   {BACKUP_PREFIX}/20261120T031500Z/aliases.json
#   {BACKUP_PREFIX}/20261120T031500Z/MANIFEST.txt    written last: collections, sizes, SHA-256
#   {BACKUP_PREFIX}/20261120T031500Z/RESTORED-*.txt  written after a restore from this run
#
# Restore: Qdrant itself downloads every snapshot of the run through a short-lived presigned
# Bucket URL (PUT /collections/{c}/snapshots/recover, priority "snapshot", checksum checked),
# so nothing large passes through this job. A collection with the same name is replaced;
# other collections are left alone. The RESTORED marker makes the restore one-shot.
#
# Retention: complete runs older than BACKUP_RETENTION_DAYS are deleted, but the newest
# BACKUP_KEEP_MIN complete runs are always kept. Incomplete runs older than two days are
# deleted. A failed run deletes nothing.
set -Eeuo pipefail

# shellcheck source=qdrant-s3.sh
. /usr/local/lib/qdrant-backup/qdrant-s3.sh

QDRANT="${QDRANT_URL:-}"
QDRANT="${QDRANT%/}"
API_KEY="${QDRANT_API_KEY:-}"
RESTORE_FROM="${QDRANT_RESTORE_FROM:-}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-300}"
TIMEOUT_SECONDS="${BACKUP_TIMEOUT_SECONDS:-3600}"
INCOMPLETE_GRACE_DAYS=2
WORK_DIR=""
CURRENT_RUN=""

log() { printf '[qdrant-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
  if [ -n "${WORK_DIR}" ]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

uint_or_default() {
  local name="$1" value="$2" min="$3" default="$4"
  if [[ "${value}" =~ ^[0-9]{1,9}$ ]] && [ "${value}" -ge "${min}" ]; then
    printf '%s' "${value}"
  else
    log "WARNING: ${name} must be a whole number >= ${min} (got '${value}'); using ${default}" >&2
    printf '%s' "${default}"
  fi
}

validate_settings() {
  RETENTION_DAYS="$(uint_or_default BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1 14)"
  KEEP_MIN="$(uint_or_default BACKUP_KEEP_MIN "${KEEP_MIN}" 1 3)"
  WAIT_SECONDS="$(uint_or_default BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0 300)"
  TIMEOUT_SECONDS="$(uint_or_default BACKUP_TIMEOUT_SECONDS "${TIMEOUT_SECONDS}" 60 3600)"
  [[ "${QDRANT}" =~ ^https?://[^[:space:]]+$ ]] || die "QDRANT_URL must be an http(s) URL (got '${QDRANT}')"
  [ -n "${API_KEY}" ] || die "QDRANT_API_KEY is empty"
  WORK_DIR="$(mktemp -d /tmp/qdrant-backup.XXXXXX)"
  # The API key travels in a header file (0600), never on the command line.
  printf 'api-key: %s\n' "${API_KEY}" > "${WORK_DIR}/headers"
  chmod 0600 "${WORK_DIR}/headers"
}

# qapi METHOD PATH [curl args...]: JSON call against Qdrant, body on stdout.
qapi() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body --retry 3 --retry-all-errors --connect-timeout 20 \
    -m "${TIMEOUT_SECONDS}" -X "${method}" -H @"${WORK_DIR}/headers" \
    -H 'Content-Type: application/json' "$@" "${QDRANT}${path}"
}

uri() { jq -rn --arg v "$1" '$v | @uri'; }

wait_for_qdrant() {
  local waited=0 code
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 -m 20 "${QDRANT}/readyz" || true)"
    [ "${code}" = 200 ] && break
    [ "${waited}" -lt "${WAIT_SECONDS}" ] || die "Qdrant at ${QDRANT} not ready after ${WAIT_SECONDS}s (HTTP ${code})"
    log "waiting for Qdrant at ${QDRANT} (HTTP ${code})"
    sleep 10
    waited=$((waited + 10))
  done
  QDRANT_VERSION="$(qapi GET / | jq -r '.version // "unknown"')" \
    || die "Qdrant rejected the API key (check QDRANT_API_KEY = the Qdrant service's QDRANT__SERVICE__API_KEY)"
  log "Qdrant ${QDRANT_VERSION} at ${QDRANT} is ready"
}

run_backup() {
  local run_id dest names name i=0 file enc info sname size sum remote_bytes count manifest
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${S3_REMOTE}/${run_id}"
  manifest="${WORK_DIR}/MANIFEST.txt"
  names="$(qapi GET /collections | jq -r '.result.collections[].name')" || die "cannot list collections"
  count="$(printf '%s' "${names}" | grep -c . || true)"
  log "starting run ${run_id}: ${count} collection(s) -> ${S3_PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET}"
  {
    printf 'run=%s\n' "${run_id}"
    printf 'qdrant_version=%s\n' "${QDRANT_VERSION}"
    printf 'collections=%s\n' "${count}"
  } > "${manifest}"

  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    i=$((i + 1))
    file="$(printf '%04d.snapshot' "${i}")"
    enc="$(uri "${name}")"
    info="$(qapi POST "/collections/${enc}/snapshots?wait=true")" \
      || die "snapshot of collection '${name}' failed: ${info:-no reply}; run ${run_id} is incomplete"
    sname="$(printf '%s' "${info}" | jq -r '.result.name')"
    size="$(printf '%s' "${info}" | jq -r '.result.size')"
    sum="$(printf '%s' "${info}" | jq -r '.result.checksum // ""')"
    log "collection '${name}': snapshot ${sname} (${size} bytes), uploading as ${file}"
    if ! curl -sS --fail --connect-timeout 20 -m "${TIMEOUT_SECONDS}" -H @"${WORK_DIR}/headers" \
         "${QDRANT}/collections/${enc}/snapshots/$(uri "${sname}")" \
         | rclone rcat --retries 1 "${dest}/${file}" 2>&1; then
      qapi DELETE "/collections/${enc}/snapshots/$(uri "${sname}")?wait=true" > /dev/null 2>&1 || true
      die "upload of collection '${name}' failed; run ${run_id} is incomplete (no MANIFEST.txt)"
    fi
    remote_bytes="$(rclone size --json "${dest}/${file}" 2>/dev/null | jq -r '.bytes // empty')"
    qapi DELETE "/collections/${enc}/snapshots/$(uri "${sname}")?wait=true" > /dev/null \
      || log "WARNING: could not delete snapshot ${sname} from the Qdrant volume"
    [ "${remote_bytes}" = "${size}" ] \
      || die "uploaded ${file} has ${remote_bytes:-unknown} bytes, Qdrant reported ${size}; run ${run_id} is incomplete"
    printf 'snapshot=%s\t%s\t%s\t%s\n' "${file}" "${size}" "${sum}" "${name}" >> "${manifest}"
  done <<< "${names}"

  qapi GET /aliases | jq '.result.aliases' > "${WORK_DIR}/aliases.json" || die "cannot list aliases"
  rclone copyto --retries 3 "${WORK_DIR}/aliases.json" "${dest}/aliases.json" 2>&1 \
    || die "upload of aliases.json failed; run ${run_id} is incomplete"
  {
    printf 'aliases=%s\n' "$(jq length "${WORK_DIR}/aliases.json")"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'restore=set QDRANT_RESTORE_FROM=%s on the Qdrant Backup service and run it once\n' "${run_id}"
  } >> "${manifest}"
  rclone copyto --retries 3 "${manifest}" "${dest}/MANIFEST.txt" 2>&1 \
    || die "upload of MANIFEST.txt failed; run ${run_id} is incomplete"
  log "run ${run_id} complete (${count} collection(s))"
  CURRENT_RUN="${run_id}"
}

# restore_run RUN: one-shot restore of a complete run. Returns 0 when done or skipped.
restore_run() {
  local run="$1" src manifest file size sum name enc url body result
  if ! [[ "${run}" =~ ${S3_RUN_RE} ]]; then
    log "WARNING: QDRANT_RESTORE_FROM='${run}' is not a run name like 20261120T031500Z; no restore (see: qdrant-backup list)"
    return 0
  fi
  src="${S3_REMOTE}/${run}"
  # rclone cat exits 0 for missing objects on bucket remotes: check the content (STANDARD 8.23).
  manifest="$(rclone cat "${src}/MANIFEST.txt" 2>/dev/null || true)"
  if ! printf '%s\n' "${manifest}" | grep -q "^run=${run}\$"; then
    log "WARNING: run ${run} has no complete MANIFEST.txt in the Bucket; no restore"
    return 0
  fi
  if rclone lsf "${src}/" 2>/dev/null | grep -q '^RESTORED-'; then
    log "run ${run} was already restored (RESTORED marker present); clear QDRANT_RESTORE_FROM"
    return 0
  fi
  log "restoring run ${run}"
  while IFS=$'\t' read -r file size sum name; do
    file="${file#snapshot=}"
    [ -n "${file}" ] && [ -n "${name}" ] || continue
    enc="$(uri "${name}")"
    url="$(rclone link --expire 2h "${src}/${file}" 2>/dev/null)" || die "cannot create a download link for ${file}"
    body="$(jq -n --arg l "${url}" --arg c "${sum}" \
      '{location: $l, priority: "snapshot"} + (if $c == "" then {} else {checksum: $c} end)')"
    log "collection '${name}': recovering from ${file} (${size} bytes)"
    result="$(qapi PUT "/collections/${enc}/snapshots/recover?wait=true" --data "${body}")" \
      || die "recovery of collection '${name}' failed: ${result:-no reply}"
  done < <(printf '%s\n' "${manifest}" | grep '^snapshot=')

  rclone cat "${src}/aliases.json" 2>/dev/null \
    | jq -c '[.[] | {create_alias: {collection_name: .collection_name, alias_name: .alias_name}}] | select(length > 0) | {actions: .}' \
    > "${WORK_DIR}/alias-actions.json" || true
  if [ -s "${WORK_DIR}/alias-actions.json" ]; then
    qapi POST /collections/aliases --data @"${WORK_DIR}/alias-actions.json" > /dev/null \
      || log "WARNING: could not recreate the aliases (they may already exist)"
  fi
  printf 'restored=%s\nqdrant_version=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${QDRANT_VERSION}" > "${WORK_DIR}/restored.txt"
  rclone copyto --retries 3 "${WORK_DIR}/restored.txt" "${src}/RESTORED-$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1 \
    || log "WARNING: could not write the RESTORED marker; clear QDRANT_RESTORE_FROM to avoid a second restore"
  log "restore of run ${run} complete; clear QDRANT_RESTORE_FROM on the Qdrant Backup service"
}

prune() {
  local now cutoff incomplete_cutoff run total keep protected=" " complete=" "
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  total=0
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    complete="${complete}${run} "
    total=$((total + 1))
  done < <(s3_list_complete_runs)
  keep=$((total - KEEP_MIN))
  for run in ${complete}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s); keep ${RETENTION_DAYS} days (delete before ${cutoff}), at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    case "${complete}" in
      *" ${run} "*)
        [[ "${run}" < "${cutoff}" ]] || continue
        log "deleting expired run ${run}"
        ;;
      *)
        [[ "${run}" < "${incomplete_cutoff}" ]] || continue
        log "deleting incomplete run ${run}"
        ;;
    esac
    rclone purge "${S3_REMOTE}/${run}" 2>&1 || log "WARNING: could not delete ${run}"
  done < <(s3_list_runs)
}

main() {
  local cmd="${1:-auto}"
  case "${cmd}" in
    auto|backup)
      validate_settings
      s3_configure || die "${S3_ERROR}"
      wait_for_qdrant
      if [ "${cmd}" = auto ] && [ -n "${RESTORE_FROM}" ]; then
        restore_run "${RESTORE_FROM}"
      fi
      run_backup
      prune
      log "done"
      ;;
    list)
      s3_configure || die "${S3_ERROR}"
      s3_show_runs
      ;;
    *)
      die "unknown command '${cmd}' (use: backup, list)"
      ;;
  esac
}

main "$@"
