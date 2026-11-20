# Qdrant v1.20 Vector Database with Backups: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Qdrant v1.20 Vector Database with Backups** (41 chars; Qdrant's own `v1.x` naming, minor = the pinned release line) |
| Description | Vector search engine with API keys, web dashboard and nightly backups. (70 chars) |
| Category | AI/ML |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/qdrant.svg` (200, image/svg+xml) |

## Base market templates

| Market template | Active | What it does | Kept | Problems fixed |
|---|---|---|---|---|
| `i1tz3T` "Qdrant" (leader) | 281 | `qdrant/qdrant:v1.19.0`, API key + read-only key from `secret(64)`, volume `/qdrant/storage`, `/readyz` healthcheck | keys from `secret()`, `/readyz` | 1.19.0 (two patch releases and one minor behind); snapshots go to `/qdrant/snapshots`, outside the volume, so they vanish on redeploy; no backups; an empty or short key typed into the deploy form leaves the API open; IPv4-only listener; telemetry on |
| `qdrant` | 44 | untagged `qdrant/qdrant`, no API key | nothing | **No API key: anyone can read and delete collections**; floating tag; no healthcheck |
| `n8n-2-ai-agent-stack-ollama-qdrant` (ours) | 0 | Qdrant 1.19.2 inside an n8n stack | `::` listener, telemetry off | — |

## Pinned versions (checked 2026-11-20)

| Component | Image | Released |
|---|---|---|
| Qdrant | `qdrant/qdrant:v1.20.2@sha256:d277592721d2e3b73f9b797b53cf05e6a5bb2134f6d13fdbda4ca51782afbcac` | 2026-11-16 |
| Backup base | `alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf` | 2026-11-08 |
| rclone | `rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5` | 2026-10-09 |

## Services

### Qdrant
- Source: repo `baranberkay96/qdrant-railway`, `/services/qdrant` (official image + `qdrant-railway.sh` start wrapper).
- Public domain → 6333 (REST + `/dashboard`). gRPC 6334 on the private network only.
- Volume `/qdrant/data`: `storage/`, `snapshots/`, `tmp/` (all three paths set by variables, so snapshots and temp files are on the volume).
- Healthcheck `/readyz` (served without a key), timeout 600 s (large collections load before ready). Restart ALWAYS. Draining 30 s.
- Wrapper: key shorter than 16 chars or empty → random key, API locked, log tells how to fix (Rule 8.29); short read-only key → read-only access off; warns if no volume is mounted; then `exec ./entrypoint.sh` (keeps Qdrant's OOM recovery).

### Qdrant Backup (cron `15 3 * * *`, restart NEVER)
- Source: same repo, `/services/backup` (Alpine + bash, curl, jq, rclone).
- Per collection: `POST /collections/{c}/snapshots?wait=true` → stream `GET …/snapshots/{name}` into `rclone rcat` → compare Bucket size with Qdrant's reported size → `DELETE` the snapshot from the volume. `aliases.json`, then `MANIFEST.txt` last.
- Restore: `QDRANT_RESTORE_FROM={run}` → for each collection, `rclone link` (presigned, 2 h) and `PUT /collections/{c}/snapshots/recover` with `priority: snapshot` and the recorded SHA-256; aliases recreated; `RESTORED-{time}.txt` marker makes it one-shot. Then a normal backup.
- Retention: 14 days, newest 3 complete runs always kept; incomplete runs deleted after 2 days; a failed run deletes nothing.
- Bad numeric settings fall back to defaults with a warning; an unknown run name only logs a warning.

### Bucket
Railway Bucket `Bucket` (virtual-hosted style).

## Resource estimate

| Service | Idle RAM | Typical | CPU |
|---|---|---|---|
| Qdrant | ~60–90 MB empty | grows with vectors: ~1.2 GB per 1M × 768-dim float32 vectors with HNSW in RAM (less with quantization/on-disk) | low idle, bursts on indexing |
| Qdrant Backup | 0 (runs ~1 min a day, ~30 MB) | — | — |

Empty project: about $1–2/month (RAM ~0.08 GB ≈ $0.80, volume and Bucket by usage). Typical 1M-vector RAG store: ~1.5 GB RAM ≈ $15/month + storage. Trial (1 GB/service) fits small collections; Hobby or Pro for production.

## Improvements over market templates

1. Pinned v1.20.2 by digest (leader on 1.19.0).
2. Snapshots and temp files on the volume (leader writes them to the container layer).
3. Nightly per-collection backups to a Railway Bucket, with checks, manifest, retention and a one-shot restore (no market template has backups).
4. Fail-closed key handling for values typed into the deploy form.
5. Dual-stack listener, telemetry off, draining time, `QDRANT_URL`/`QDRANT_PRIVATE_URL` helper variables.

## Verification checklist

- [ ] Both services build; Qdrant SUCCESS, `/readyz` 200.
- [ ] `GET /collections` without key → 401; with full key → 200; read-only key can search but not upsert (403).
- [ ] `/dashboard` loads and accepts the full key.
- [ ] Create a collection, upsert points, search.
- [ ] Run Qdrant Backup → run folder with `.snapshot`, `aliases.json`, `MANIFEST.txt`; local snapshot deleted.
- [ ] Delete the collection, set `QDRANT_RESTORE_FROM`, run the job → collection and points back; second run does not restore again.
- [ ] Redeploy Qdrant → collection persists.
- [ ] Short API key (e.g. `abc`) → deploy succeeds, API answers 401 to everyone, log explains.

## Open questions

- Railway Bucket presigned URLs from `rclone link` must be reachable by Qdrant (public endpoint over HTTPS); verified in the deploy test.
- Snapshots of very large collections need free volume space for one snapshot at a time.
