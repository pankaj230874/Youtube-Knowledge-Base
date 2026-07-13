-- =====================================================================
-- YouTube AI Knowledge Base — Supabase (Postgres + pgvector) schema
-- Run this once in the Supabase SQL editor before activating Workflow 1.
-- =====================================================================

create extension if not exists vector;
create extension if not exists pgcrypto; -- for gen_random_uuid()

-- ---------------------------------------------------------------------
-- videos: one row per source video
-- ---------------------------------------------------------------------
create table if not exists videos (
  id uuid primary key default gen_random_uuid(),
  video_id text unique not null,          -- YouTube's 11-char ID
  title text,
  channel_name text,
  url text not null,
  duration_seconds int,
  transcript_source text,                 -- timedtext | scraped | apify-caption | apify-whisper | none
  status text default 'pending',          -- pending | fetching | embedded | failed
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create index if not exists idx_videos_status on videos (status);
create index if not exists idx_videos_updated_at on videos (updated_at);

-- ---------------------------------------------------------------------
-- chunks: many rows per video
-- ---------------------------------------------------------------------
create table if not exists chunks (
  id uuid primary key default gen_random_uuid(),
  video_id uuid references videos(id) on delete cascade,
  chunk_index int not null,
  content text not null,
  start_seconds numeric,
  end_seconds numeric,
  token_count int,
  embedding vector(768),                  -- matches Gemini text-embedding-004
  created_at timestamptz default now(),
  unique (video_id, chunk_index)
);

-- Vector similarity index. Start with IVFFlat; move to HNSW past ~50k chunks
-- (see "Scaling" note at the bottom of this file).
create index if not exists idx_chunks_embedding
  on chunks using ivfflat (embedding vector_cosine_ops) with (lists = 100);

create index if not exists idx_chunks_video_id on chunks (video_id);
create index if not exists idx_chunks_created_at on chunks (created_at);

-- ---------------------------------------------------------------------
-- Semantic search RPC used by Workflow 2 (Knowledge Retrieval)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table videos enable row level security;
alter table chunks enable row level security;

drop policy if exists "service role full access videos" on videos;
create policy "service role full access videos" on videos
  for all using (auth.role() = 'service_role');

drop policy if exists "service role full access chunks" on chunks;
create policy "service role full access chunks" on chunks
  for all using (auth.role() = 'service_role');

drop policy if exists "public read videos" on videos;
create policy "public read videos" on videos
  for select using (true);

drop policy if exists "public read chunks" on chunks;
create policy "public read chunks" on chunks
  for select using (true);

-- =====================================================================
-- Reference queries used by Workflow 1 (Ingestion) — for documentation only,
-- these are already embedded as Postgres node "executeQuery" parameters.
-- =====================================================================

-- Upsert a video row and get its UUID back:
-- insert into videos (video_id, title, channel_name, url, transcript_source, status)
-- values ($1, $2, $3, $4, $5, $6)
-- on conflict (video_id) do update set
--   title = excluded.title, channel_name = excluded.channel_name,
--   transcript_source = excluded.transcript_source, status = excluded.status, updated_at = now()
-- returning id, video_id;

-- Insert a chunk with its embedding:
-- insert into chunks (video_id, chunk_index, content, start_seconds, end_seconds, token_count, embedding)
-- values ($1, $2, $3, $4, $5, $6, $7::vector)
-- on conflict (video_id, chunk_index) do nothing;

-- =====================================================================
-- Reference queries used by Workflow 4 (Maintenance)
-- =====================================================================

-- Find videos to reprocess after 90 days (model/content drift):
-- select video_id from videos where status = 'embedded' and updated_at < now() - interval '90 days';

-- Find lower-confidence Whisper-sourced chunks to re-embed periodically:
-- select c.id, c.content from chunks c join videos v on v.id = c.video_id
-- where v.transcript_source = 'apify-whisper' and c.created_at < now() - interval '30 days' limit 200;

-- Update a chunk's embedding in place:
-- update chunks set embedding = $2::vector where id = $1::uuid;

-- Remove duplicate chunks (same video + chunk_index), keeping the lowest id:
-- delete from chunks a using chunks b
-- where a.id > b.id and a.video_id = b.video_id and a.chunk_index = b.chunk_index;
-- NOTE: with the unique (video_id, chunk_index) constraint above, true duplicates can
-- only be created by application bugs bypassing "on conflict do nothing" — this query
-- is a defensive backstop and should normally return 0 rows.

-- Clean orphan chunks (video was deleted but cascade didn't run, e.g. manual delete):
-- delete from chunks where video_id not in (select id from videos);

-- Reset videos stuck in 'fetching' for over 2 hours (crashed execution):
-- update videos set status = 'failed' where status = 'fetching' and updated_at < now() - interval '2 hours';

-- =====================================================================
-- Scaling notes (see Architecture Doc §5, §9)
-- =====================================================================
-- - Storage estimate: 10,000 videos × ~6 chunks × 768 dims × 4 bytes ≈ 184 MB raw
--   vector data — comfortably inside the 500 MB free tier before ~10-15k videos.
-- - At ~10-15k videos: upgrade to Supabase Pro ($25/mo) for more storage/compute.
-- - Past ~50k chunks: switch the ivfflat index to hnsw for better recall:
--     drop index idx_chunks_embedding;
--     create index idx_chunks_embedding on chunks using hnsw (embedding vector_cosine_ops);
-- - No backups on the free tier — schedule a weekly `pg_dump` via a small n8n
--   workflow to object storage (e.g. Google Drive / S3) as insurance.
