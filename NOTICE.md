# NOTICE

This is a community template for running Qdrant on Railway. It is not affiliated with or endorsed by Qdrant Solutions GmbH or Railway. This file lists what the template uses, where it comes from and under which license. It is a summary for attribution, not legal advice.

## Software the template runs (unmodified)

| Component | Version | Source | License |
|---|---|---|---|
| Qdrant | v1.20.2, image `qdrant/qdrant:v1.20.2@sha256:d277592721d2e3b73f9b797b53cf05e6a5bb2134f6d13fdbda4ca51782afbcac` | https://github.com/qdrant/qdrant | Apache-2.0, Copyright Qdrant Solutions GmbH and contributors |
| Qdrant web UI (in the image, `/qdrant/static`) | bundled with v1.20.2 | https://github.com/qdrant/qdrant-web-ui | Apache-2.0 |
| Debian base (from the Qdrant image) | 13 slim | https://www.debian.org | Debian packages under their own free-software licenses |
| Alpine Linux (backup job) | 3.24.4, `alpine@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf`; packages bash, curl, jq, coreutils, ca-certificates, tzdata | https://alpinelinux.org | Packages under their own licenses (GPL-3.0 bash/coreutils, curl license, MIT jq, MPL-2.0 CA data) |
| rclone | 1.75.2, static binary copied from `rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5` | https://github.com/rclone/rclone | MIT, Copyright (C) 2012 by Nick Craig-Wood |

Qdrant itself is not patched. The Qdrant image gets one extra file, `qdrant-railway.sh`, which checks the API keys and creates folders before it runs the image's own `entrypoint.sh`.

## Files written for this template

`services/qdrant/Dockerfile`, `services/qdrant/qdrant-railway.sh`, `services/backup/Dockerfile`, `services/backup/qdrant-backup.sh`, `template.json`, `TEMPLATE.md` and `README.md` were written for this template. `services/backup/qdrant-s3.sh` and the retention logic in `qdrant-backup.sh` are adapted from this author's Valkey template (`baranberkay96/valkey-railway`). No file or text was copied from the marketplace templates or from Qdrant's documentation.

## Upstream files and versions checked (2026-11-20)

- `qdrant/qdrant` at `v1.20.2`: `Dockerfile` (Debian 13 slim runtime, user 0, `WORKDIR /qdrant`, `CMD ./entrypoint.sh`), `tools/entrypoint.sh` (OOM recovery mode), `config/config.yaml` (`storage_path`, `snapshots_path`, `temp_path`, `service.host`, `api_key`, `read_only_api_key`, `telemetry_disabled`), `src/settings.rs` (environment prefix `QDRANT` with separator `__`).
- Qdrant REST API (v1.20): `GET /readyz`, `GET /collections`, `POST /collections/{name}/snapshots`, `GET`/`DELETE /collections/{name}/snapshots/{snapshot}`, `PUT /collections/{name}/snapshots/recover` (`location`, `priority`, `checksum`), `GET /aliases`, `POST /collections/aliases`.
- Releases page: v1.20.2 published 2026-11-16 (latest stable on 2026-11-20).
