# YouTube AI Knowledge Base — Architecture Design Document
### n8n Cloud + Supabase + Free-Tier AI Stack
**Status:** Draft for approval — no workflow has been built yet.

---

## 1. Architecture Diagram

```
┌─────────────────┐
│  Google Sheets   │  (Video URL, Status, Metadata)
│  "Video Queue"   │
└────────┬─────────┘
         │ Schedule Trigger (every 15 min, or manual "Add Video" form)
         ▼
┌─────────────────────────────┐
│  INGESTION WORKFLOW (n8n)    │
│  1. Read rows where          │
│     status = "Pending"       │
│  2. Loop Over Items (batch=1)│
│  3. Extract videoId          │
│  4. Try: Native captions      │
│     (timedtext / yt-dlp path)│
│  5. Fallback: Apify Whisper   │
│     AI-fallback actor         │
│  6. Clean + normalize text    │
│  7. Chunk (recursive, ~500tok)│
│  8. Embed chunks (Gemini      │
│     text-embedding-004)       │
│  9. Upsert to Supabase        │
│  10. Update Sheet status      │
│  11. On error → Slack/Email   │
└────────┬─────────────────────┘
         ▼
┌─────────────────────────────┐
│  SUPABASE (Postgres)         │
│  - videos (metadata)          │
│  - chunks (text + tokens)     │
│  - embeddings (pgvector)      │
│  - match_chunks() RPC         │
│  - RLS policies                │
└────────┬─────────────────────┘
         ▲
         │ Vector Store Retriever (top-k cosine)
┌─────────────────────────────┐
│  RAG CHATBOT WORKFLOW (n8n)  │
│  Chat Trigger → AI Agent      │
│  + Gemini Flash Chat Model    │
│  + Supabase Vector Store       │
│  + Simple Memory (buffer)      │
│  → Response with citations     │
│  (video title + timestamp link)│
└─────────────────────────────┘
```

---

## 2. Challenging the Original Assumptions

The inspiration workflow assumed: RapidAPI-based transcript fetching, OpenAI embeddings, and a generic vector store. All three are rejected here:

- **RapidAPI transcript wrappers** are unreliable resellers of the same public endpoints you can call directly — no accuracy or reliability benefit, and they add a paid middleman with no SLA.
- **OpenAI embeddings** are explicitly excluded by your constraints, and are no cheaper or better than the free alternative for this use case.
- **Pinecone** is unjustified here — you're not at the 50M+ vector scale where a dedicated vector DB earns its complexity and cost. Supabase/pgvector keeps metadata and vectors in one transactional store, which matters a lot for a 100 → 10,000 video knowledge base with per-video status tracking.

---

## 3. Component Evaluation

### 3.1 Transcript Providers

| Option | Free tier | Handles no-caption videos? | Reliability | Effort | Verdict |
|---|---|---|---|---|---|
| **YouTube Data API v3 `captions.download`** | 10,000 units/day | No (owner-only, manual captions) | High but useless for 3rd-party videos | Low | ❌ Not viable — you don't own the videos |
| **Undocumented `timedtext` XML endpoint** | Unlimited, 0 quota | No | Medium — undocumented, can break silently | Low | ✅ Use as **primary path** (free, instant, zero quota) |
| **`youtube-transcript-api`-style scraping (Code node)** | Unlimited | No | Medium — breaks when YouTube changes markup; IP-block risk on cloud | Medium | ✅ Use as **secondary fallback** before paid AI path |
| **Supadata API** | 100 credits/month free | Yes (AI fallback) | High, purpose-built, n8n integration exists | Low | ⚠️ Good for MVP (100 videos), too small for 10k/month free |
| **Apify "YouTube Transcript Scraper — Captions & AI Fallback"** | Pay-per-event (no monthly subscription); ~$0.001/video for captioned, $0.012/min for AI fallback | Yes (bundled faster-Whisper, no external key) | High — production-grade, dry-run cost preview | Low (HTTP Request node to Apify API) | ✅ **Use as tertiary fallback**, only triggered for the ~10-20% of videos with no captions |

**Recommendation — 3-tier waterfall:**
1. **Tier 1 (free, 0 cost):** Fetch `https://video.google.com/timedtext?lang=en&v={videoId}` directly via HTTP Request node. Covers the majority of videos with native/auto captions at zero cost and zero quota.
2. **Tier 2 (free, 0 cost):** If Tier 1 returns empty, retry via a Code node replicating `youtube-transcript-api` logic (scrapes the same public caption manifest with a different parsing path). Catches edge cases where the direct endpoint format changed.
3. **Tier 3 (paid, but tiny cost):** If both fail (no captions exist at all), call the Apify actor with `dryRun` first to preview cost, then run with `maxAiMinutes` capped. This is the **only** paid step in the entire pipeline, and only fires for genuinely caption-less videos — typically a small minority.

Why this beats a single-vendor approach: it costs $0 for ~80-90% of your library, and isolates the only unavoidable paid dependency (audio-based STT) to the smallest possible surface area — with a hard spend cap (`maxAiMinutes`).

### 3.2 Speech-to-Text (fallback for zero-caption videos)

Since Docker/self-hosted Whisper is off the table, you cannot run STT for free at unlimited volume. Options compared:

| Option | Free tier | Cost at scale | Reliability | Verdict |
|---|---|---|---|---|
| Google Cloud STT | 60 min free, then $0.96/hr | Requires GCS bucket, most setup friction | High | ❌ Too much setup for marginal benefit |
| AssemblyAI | $50 credit (~185 hrs) | $0.15–0.21/hr after | High | ⚠️ Viable backup if Apify fallback is disabled |
| Deepgram | $200 credit (~460 hrs) | $0.26–0.46/hr after | Highest accuracy/cost ratio | ⚠️ Best pure-STT option if you outgrow Apify |
| **Apify bundled faster-Whisper (via the transcript actor above)** | Pay-per-event, $0.012/min | Same, scales linearly | High, already integrated with transcript fallback | ✅ **Recommended** — avoids running two separate vendors for the same job |

Using Apify for *both* caption scraping and AI fallback avoids maintaining two separate credentials/vendors for what is functionally one step in the pipeline. Deepgram's $200 free credit is a good emergency backup if Apify's per-event pricing becomes unpredictable at 10,000-video scale — worth wiring as a secondary HTTP path but not the default.

### 3.3 Embedding Providers

| Option | Free tier | Quality (MTEB) | Dimensions | Verdict |
|---|---|---|---|---|
| **Google Gemini `text-embedding-004` / `gemini-embedding-001`** | Free, ~10M tokens/min, no monthly cap disclosed | ~63 (mid-pack, adequate for domain-specific RAG) | 768 (truncatable) | ✅ **Recommended** |
| Cohere Embed v4 | ~100 calls/month practical free tier | Higher (top-tier) | 1024+ | ❌ Free tier too small for 10k-video scale |
| Voyage AI voyage-4-lite | 200M tokens free (one-time) | Strong | 512–1024 | ⚠️ Good one-time allowance, but not renewing/free forever |
| HuggingFace Inference API (open models) | Free, rate-limited, cold starts | Variable | Variable | ❌ Too unreliable for a production pipeline via HTTP nodes |

**Recommendation:** Google's `text-embedding-004` (or its successor `gemini-embedding-001`) is genuinely free indefinitely on the free tier (not a one-time credit), has native n8n HTTP support, and 768 dimensions keeps your Supabase storage footprint small. At 10,000 videos × ~6 chunks × 768 dims × 4 bytes ≈ **184 MB of raw vector data** — comfortably inside free-tier Postgres storage even before compression.

Migration path: if retrieval quality becomes the bottleneck later, Voyage AI's shared embedding space (v4 family) allows swapping tiers without a full re-index — worth keeping as the paid upgrade path rather than switching providers entirely.

### 3.4 Vector Database / Metadata Storage

| Option | Free tier | Fit for 100→10k videos | Verdict |
|---|---|---|---|
| **Supabase (pgvector)** | 500 MB DB, free forever, RLS, SQL functions included | Vectors + metadata in one transactional store; 500MB supports comfortably up to ~10-15k videos at 768 dims before needing Pro ($25/mo) | ✅ **Recommended** — matches your stated preference and constraint list |
| Pinecone | 2 GB free (serverless) | Requires syncing metadata separately (two systems to keep consistent) | ❌ Unjustified extra complexity at this scale |
| Qdrant Cloud | 1 GB free cluster | Good alternative, but separates metadata from vectors | ⚠️ Viable backup, not primary |

Supabase wins because n8n has a native Supabase node and Vector Store node, RLS lets you scope access per-user later (if you add a chatbot UI with logins), and your metadata (video title, status, timestamps) lives next to the vectors — no dual-write consistency problem.

### 3.5 Chunking Strategy

- **Recursive character/token splitting**, target **500 tokens per chunk with 15% overlap (~75 tokens)**. Video transcripts are conversational and rarely have clean paragraph breaks, so a fixed-size recursive splitter (respecting sentence boundaries where possible) outperforms semantic/paragraph-based chunking here.
- Store the **start/end timestamp range** for each chunk (from the caption offsets) — this is what enables "jump to this moment in the video" citations later.
- Avoid chunking below ~300 tokens: too small hurts retrieval context; avoid above ~800: dilutes embedding relevance for a specific question.

### 3.6 Chat Model (RAG generation)

Excluded: OpenAI Chat Models, Claude API (per your constraints).

| Option | Free tier | Verdict |
|---|---|---|
| **Gemini 2.5/3 Flash-Lite** | 1,000–1,500 requests/day, 15-30 RPM, 1M context, free indefinitely | ✅ **Recommended** for the chatbot's answer-generation step |
| Gemini 2.5 Pro | Only 50 RPD free | ❌ Too restrictive for a chatbot |
| Mistral (La Plateforme) | Trial credits only, not renewing | ❌ Not sustainable free |

Flash-Lite's 1M-token context window is enough to stuff in retrieved chunks + conversation memory without hitting context limits, and its daily free quota (1,000-1,500 requests) comfortably covers a small-to-medium internal knowledge-base chatbot.

### 3.7 Retry / Error Handling Architecture

- Every external HTTP node (`timedtext`, Apify, Gemini) set to `onError: continueRegularOutput`, so one failing video never kills the batch.
- A dedicated **Error Trigger workflow** captures failures, writes the failure reason back to the Google Sheet row (`Transcript Status = "Failed: <reason>"`), and posts a Slack/email alert.
- **Wait node** (1–2 seconds) between Gemini embedding calls to respect free-tier RPM limits; **Loop Over Items** with batch size 1 for the AI-heavy steps, batch size 10-50 for cheap steps (Sheet reads, status updates).
- Idempotency: before inserting, check `videos.video_id` uniqueness in Supabase (upsert on conflict) so a re-run of a partially-failed batch doesn't duplicate chunks.

### 3.8 Workflow Orchestration

Two separate n8n workflows, not one monolith:
1. **Ingestion workflow** (Schedule Trigger) — polls the Sheet, processes new/failed videos.
2. **Chatbot workflow** (Chat Trigger) — always-on, queries Supabase, never touches ingestion logic.

This separation means a slow ingestion run (large playlist import) never blocks or rate-limits the live chatbot, and you can scale/debug them independently.

---

## 4. Redesigned Google Sheet Schema

| Column | Purpose |
|---|---|
| `Video URL` | Input — source of truth for what to process |
| `Video ID` | Extracted once, avoids re-parsing the URL everywhere downstream |
| `Video Title` | Populated from oEmbed/metadata fetch; shown in chatbot citations |
| `Channel Name` | Useful filter/facet for search later |
| `Duration (sec)` | Needed to estimate Apify AI-fallback cost before running it |
| `Transcript Status` | `Pending / Fetching / Fetched-Native / Fetched-AI / Failed / Embedded` — granular states let you re-drive only what actually needs it |
| `Transcript Source` | `timedtext / scraped / apify-caption / apify-whisper` — critical for auditing transcript quality later |
| `Chunk Count` | Sanity check — flags suspiciously short/long transcripts |
| `Process Date` | When ingestion completed |
| `Error Message` | Last failure reason, for manual triage |
| `Priority` | Optional — lets you queue-jump important videos in a 10k backlog |

The original 5-column schema had no way to distinguish "haven't tried yet" from "tried and failed," no cost-estimation field, and no way to audit *how* a transcript was obtained — all of which matter once you're triaging thousands of rows.

---

## 5. Supabase Database Design

```sql
-- Enable pgvector
create extension if not exists vector;

-- Videos: one row per source video
create table videos (
  id uuid primary key default gen_random_uuid(),
  video_id text unique not null,          -- YouTube's 11-char ID
  title text,
  channel_name text,
  url text not null,
  duration_seconds int,
  transcript_source text,                 -- timedtext | scraped | apify-caption | apify-whisper
  status text default 'pending',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Chunks: many rows per video
create table chunks (
  id uuid primary key default gen_random_uuid(),
  video_id uuid references videos(id) on delete cascade,
  chunk_index int not null,
  content text not null,
  start_seconds numeric,                  -- for "jump to timestamp" citations
  end_seconds numeric,
  token_count int,
  embedding vector(768),                  -- matches Gemini text-embedding-004
  created_at timestamptz default now()
);

-- Vector similarity index (IVFFlat, tune `lists` as data grows)
create index on chunks using ivfflat (embedding vector_cosine_ops) with (lists = 100);

-- Helpful filter index
create index on chunks (video_id);

-- Semantic search RPC used by n8n's Supabase Vector Store node
create or replace function match_chunks(
  query_embedding vector(768),
  match_count int default 5,
  filter_video_id uuid default null
)
returns table (
  id uuid,
  video_id uuid,
  content text,
  start_seconds numeric,
  similarity float
)
language sql stable
as $$
  select
    chunks.id,
    chunks.video_id,
    chunks.content,
    chunks.start_seconds,
    1 - (chunks.embedding <=> query_embedding) as similarity
  from chunks
  where filter_video_id is null or chunks.video_id = filter_video_id
  order by chunks.embedding <=> query_embedding
  limit match_count;
$$;

-- Row Level Security
alter table videos enable row level security;
alter table chunks enable row level security;

-- Service-role (n8n) gets full access; anon/public gets read-only on chunks+videos
create policy "service role full access videos" on videos
  for all using (auth.role() = 'service_role');
create policy "service role full access chunks" on chunks
  for all using (auth.role() = 'service_role');
create policy "public read videos" on videos
  for select using (true);
create policy "public read chunks" on chunks
  for select using (true);
```

**Future scalability path:** at ~10-15k videos you'll approach the 500MB free-tier ceiling; upgrading to Supabase Pro ($25/mo) buys more storage/compute long before you'd need to consider a dedicated vector DB. Switch `ivfflat` to `hnsw` (better recall, more memory) once you're past ~50k chunks and compute allows it.

---

## 6. RAG Architecture

- **Embedding generation:** Each chunk embedded individually at ingestion time via Gemini; query embedded at chat time with the same model (critical — mixing embedding models breaks cosine similarity meaningfully).
- **Retrieval:** `match_chunks()` returns top-5 by cosine similarity, optionally filtered to a specific video if the user names one.
- **Ranking:** For MVP, cosine similarity alone is sufficient at 100-video scale. At 10,000-video scale, add a lightweight re-ranking pass — Cohere's free-tier Rerank API (small quota, but retrieval-only calls are cheap) re-orders the top 20 candidates down to the best 5, improving precision without another embedding pass.
- **Context building:** Concatenate the top chunks with their video title + timestamp prefix, e.g. `[Video: "How pgvector Works" @ 04:12] <chunk text>` — this both grounds the LLM and gives you the raw material for citations.
- **Prompt construction:** System prompt instructs the model to answer only from provided context, and to cite the video title + timestamp for every claim; falls back to "I don't have information on that" rather than hallucinating.
- **Source citation:** Because timestamps are stored per chunk, the chatbot can return a direct deep link: `https://youtube.com/watch?v={video_id}&t={start_seconds}s`.

---

## 7. Estimated Costs

| Scale | Transcript | Embeddings | Chat | Supabase | n8n Cloud | Total/month |
|---|---|---|---|---|---|---|
| MVP (100 videos) | ~$0 (Tier 1/2 covers most; a few $ in Apify AI fallback for caption-less videos) | $0 (free tier) | $0 (free tier) | $0 (free tier) | Starter plan (~$20-24/mo, if not already subscribed) | **~$20-30/mo**, mostly the n8n subscription itself |
| Scale (10,000 videos) | $10-50/mo depending on % caption-less | $0 (still within free tier at this token volume) | $0-ish (may need to throttle chatbot traffic to daily quota) | $25/mo (Pro, once >500MB) | Existing n8n Cloud plan | **~$40-80/mo** |

n8n Cloud's own subscription is the one cost that exists regardless of this architecture — everything AI-specific stays free or near-free at both scales due to the tiered free-first design.

---

## 8. Risks

- **Undocumented `timedtext` endpoint could break** if YouTube changes it — mitigated by the 3-tier fallback, but worth monitoring failure rates weekly.
- **Free-tier rate limits (Gemini RPM, Supabase pause-after-inactivity)** — the ingestion workflow's own Schedule Trigger keeps the Supabase project "active," avoiding the 7-day pause risk.
- **Whisper/AI-fallback hallucination** on noisy audio — flag `transcript_source = apify-whisper` rows for lower confidence in citations.
- **Chatbot traffic exceeding Gemini's daily free quota** if usage grows — add a simple in-workflow request counter/backoff before that becomes a production incident.
- **No backups on Supabase free tier** — schedule a weekly `pg_dump` via a small n8n workflow to object storage as insurance.

---

## 9. Future Roadmap

1. **MVP (100 videos):** ship the 3-tier ingestion + Supabase + chatbot as described, entirely on free tiers.
2. **500-2,000 videos:** add Cohere rerank step, monitor Supabase storage, consider `hnsw` index.
3. **10,000+ videos:** move to Supabase Pro, add scheduled re-embedding for stale content, add multi-language support (Gemini embeddings handle 100+ languages natively), and consider a lightweight caching layer for repeat chatbot queries to conserve free-tier chat quota.
4. **Beyond 10,000:** revisit whether a dedicated vector DB (Pinecone/Qdrant) is justified — only if query latency or vector count (50M+) genuinely outgrows pgvector.

---

**This document is for architecture approval only. No n8n workflow JSON has been generated.** Once you confirm the direction (or want to swap any component — e.g., Deepgram instead of Apify for STT, or Cohere embeddings instead of Gemini), I'll move to building the actual workflow.
