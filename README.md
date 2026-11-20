# Deploy and Host Qdrant with Railway

Qdrant is an open-source (Apache-2.0) vector database and similarity search engine written in Rust. This community template runs Qdrant v1 with a generated full-access API key and a read-only key, the built-in web dashboard behind that key, collections on a volume, and nightly collection snapshots to a Railway Bucket with retention and one-step restore.

## About Hosting Qdrant

Qdrant stores vectors with JSON payloads and answers nearest-neighbour queries with filters, hybrid (dense + sparse) search and quantization. A single node is enough for millions of vectors, but a public deployment needs a few things the plain image does not give you: an API key from the first boot (without one, anyone who finds the URL can read and delete your collections), data on a volume, and copies that live outside that volume. This template generates both keys, refuses to start the API with an empty or short key (it locks itself instead of opening up), keeps storage, snapshots and temporary files on one volume, and runs a cron job that snapshots every collection and streams it into a private Bucket. Telemetry to Qdrant is off.

## Common Use Cases

- Retrieval-augmented generation (RAG): store document chunks with embeddings and fetch the closest ones for an LLM prompt
- Semantic and hybrid search over products, tickets, docs or code, with payload filters
- Long-term memory for AI agents and chatbots (n8n, LangChain, LlamaIndex, Dify, Flowise and others ship Qdrant connectors)
- Recommendations and deduplication by vector similarity
- Image, audio or multimodal search with embeddings from any model

## Dependencies for Qdrant Hosting

- Qdrant v1.2 (built from the official `qdrant/qdrant` image, pinned by digest)
- A Railway volume at `/qdrant/data` (included)
- A Railway Bucket for backups (included, created by the template)

### Deployment Dependencies

- Qdrant documentation: https://qdrant.tech/documentation/
- Qdrant source: https://github.com/qdrant/qdrant
- Security (API keys): https://qdrant.tech/documentation/guides/security/
- Snapshots: https://qdrant.tech/documentation/concepts/snapshots/
- Railway Storage Buckets: https://docs.railway.com/storage-buckets
- Railway cron jobs: https://docs.railway.com/cron-jobs

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| Qdrant | this repo, `services/qdrant` (`FROM qdrant/qdrant:v1.20.2`) | REST API + web dashboard on the public domain (port 6333), gRPC on 6334 for the private network, volume `/qdrant/data` |
| Qdrant Backup | this repo, `services/backup` (Alpine + curl + rclone) | Cron job, daily 03:15 UTC: snapshot every collection, stream it to the Bucket, keep 14 days (at least the newest 3 runs) |
| Bucket | Railway Bucket | Private S3 storage for the snapshots |

**First steps**

1. Open the **Qdrant** service → Variables and copy `QDRANT__SERVICE__API_KEY` (full access) and `QDRANT__SERVICE__READ_ONLY_API_KEY` (search only).
2. Web dashboard: `https://{your-domain}/dashboard`, paste the full key when it asks for one.
3. Clients send the key as the `api-key` header (or `Authorization: Bearer`):

```bash
curl -H "api-key: $QDRANT_API_KEY" https://{your-domain}/collections
```

Python: `QdrantClient(url="https://{your-domain}", port=443, api_key="...")`. Apps in the same Railway project should use `QDRANT_PRIVATE_URL` (`http://qdrant.railway.internal:6333`; gRPC on port 6334) and reference the key as `${{Qdrant.QDRANT__SERVICE__API_KEY}}`.

The healthcheck uses `/readyz`, which Qdrant serves without a key. Every other route, including the dashboard's API calls, needs a key.

**Keys.** A key shorter than 16 characters (or empty) is never used: the full key is replaced by a random one nobody knows, so the API stays locked until you set a longer key and redeploy; a short read-only key turns read-only access off. The start log says which case happened. Changing `QDRANT__SERVICE__API_KEY` also updates the backup job, which references it.

**Backups.** Each run is a folder `qdrant/{UTC time}/` in the Bucket with one `.snapshot` file per collection, `aliases.json` and `MANIFEST.txt` (written last; collection names, sizes and Qdrant's SHA-256). The job streams snapshots from the API into the Bucket, so it needs no disk of its own; Qdrant needs free space on its volume for one collection snapshot at a time. To run it now, use the Railway CLI (`railway cron run` for the Qdrant Backup service) or wait for 03:15 UTC.

**Restore.** Set `QDRANT_RESTORE_FROM` on **Qdrant Backup** to a run name (for example `20261120T031500Z`) and run the job once. Qdrant downloads each snapshot through a two-hour presigned Bucket link, checks the SHA-256 and replaces the collection of the same name; other collections are not touched, and aliases are recreated. The job then takes a fresh backup and marks the run as restored, so leaving the variable set does not restore it again. Clear it afterwards.

**Scaling.** Qdrant is a single stateful node here (the volume belongs to one replica). Give it more memory as collections grow: vectors and HNSW indexes live in RAM unless you enable on-disk storage or quantization per collection. Trial-plan services (1 GB) fit small collections only. Distributed (multi-node) mode is not part of this template.

**Versions.** The Qdrant tag and digest are in `services/qdrant/Dockerfile`. To upgrade, take a backup, bump to the next minor release (Qdrant supports upgrading one minor version at a time), push, and redeploy. Release notes: https://github.com/qdrant/qdrant/releases

### Why Deploy Qdrant on Railway?

Railway runs the database, its volume, the backup cron job and the Bucket as one project with private networking between them, so your apps reach Qdrant on the internal network while external clients use HTTPS on a generated domain. You pay for the memory and storage Qdrant actually uses, and resizing, redeploying or restoring takes a few clicks.
