# Qdrant Backup (Railway cron job): collection snapshots over the Qdrant API, streamed into the
# Railway Bucket, with retention, plus a one-shot restore (see qdrant-backup.sh).
#
# Upgrade: bump the alpine and rclone tags and digests.
FROM rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5 AS rclone

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache bash curl jq ca-certificates coreutils tzdata

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=0755 qdrant-backup.sh /usr/local/bin/qdrant-backup
# 0755: BuildKit gives a directory it creates the same mode (STANDARD 8.22).
COPY --chmod=0755 qdrant-s3.sh /usr/local/lib/qdrant-backup/qdrant-s3.sh

RUN set -eu; \
    bash -n /usr/local/bin/qdrant-backup; \
    bash -n /usr/local/lib/qdrant-backup/qdrant-s3.sh; \
    rclone version > /dev/null; \
    jq --version > /dev/null; \
    curl --version | head -n 1; \
    date -u -d @0 +%Y > /dev/null

ENTRYPOINT ["/usr/local/bin/qdrant-backup"]
CMD []
