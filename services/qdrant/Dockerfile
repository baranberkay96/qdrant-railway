# Qdrant for Railway: the official image plus a start wrapper that refuses weak API keys
# without failing the deploy (see qdrant-railway.sh). Nothing else changes.
#
# Upgrade: bump the tag and digest (both from https://hub.docker.com/r/qdrant/qdrant/tags).
# Qdrant reads storage written by the previous minor version; take a backup first
# ("Qdrant Backup" cron) and upgrade one minor at a time.
FROM qdrant/qdrant:v1.20.2@sha256:d277592721d2e3b73f9b797b53cf05e6a5bb2134f6d13fdbda4ca51782afbcac

COPY --chmod=0755 qdrant-railway.sh /usr/local/bin/qdrant-railway

# Fail the build early if the image layout this wrapper relies on changes.
RUN set -eu; \
    bash -n /usr/local/bin/qdrant-railway; \
    test -x /qdrant/qdrant; \
    test -x /qdrant/entrypoint.sh; \
    for b in base64 tr head awk; do command -v "$b" > /dev/null; done; \
    /qdrant/qdrant --version | grep -q '1\.20\.2'

WORKDIR /qdrant
EXPOSE 6333 6334
ENTRYPOINT ["/usr/local/bin/qdrant-railway"]
CMD []
