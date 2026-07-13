# YouTube AI Knowledge Base — Deployment Guide

Five workflows were created in your n8n Cloud instance:

| # | Workflow | ID | Trigger |
|---|---|---|---|
| 0 | Error Handler | `--` | Error Trigger |
| 1 | YouTube Ingestion | `--` | Schedule (every 15 min) |
| 2 | Knowledge Retrieval | `--` | Execute Workflow Trigger (sub-workflow) |
| 3 | AI Chatbot | `--` | Chat Trigger (hosted) |
| 4 | Maintenance | `--` | Schedule (daily, 3 AM) |

Open any workflow at `https://n8n.coachshwetagupta.com/workflow/<ID>`.

---

## 1. Credential Setup

Create these credentials in n8n (**Credentials → Add Credential**) with the exact
names below — the workflows reference them by name and will auto-bind once created.

| Credential Name | Type | Used By | Where to get it |
|---|---|---|---|
| `Google Sheets - Video Queue` | Google Sheets OAuth2 | Workflows 1, 4 | Google Cloud Console → OAuth client (or use n8n's built-in Google OAuth) |
| `Supabase Postgres` | Postgres | Workflows 1, 2, 4 | Supabase → Project Settings → Database → Connection string (use the **Session pooler**, port 5432, `sslmode=require`) |
| `Google Gemini API Key` | Header Auth *or* Query Auth¹ | Workflows 1, 2, 3, 4 | https://aistudio.google.com/apikey |
| `Apify API Token` | Header Auth (`Authorization: Bearer <token>`) | Workflow 1 | Apify Console → Settings → Integrations |
| `Slack - KB Alerts Bot` | Slack API (OAuth) | Workflow 0 | Slack App with `chat:write` scope, invited to `#kb-alerts` |

¹ **Gemini auth note:** the HTTP Request nodes are configured with
`genericAuthType: httpQueryAuth`, meaning n8n will append your key as a `key=`
query parameter automatically. When creating the **Query Auth** credential, set:
- Name: `key`
- Value: your Gemini API key

Do this once and every Gemini-calling node in all 4 workflows will pick it up
(they all reference the same credential name).

### Google Sheet setup
Create a Google Sheet named anything you like, with one tab called **`Video Queue`**
and these columns (see §4 for the full schema):

`Video URL | Video ID | Video Title | Channel Name | Duration (sec) | Transcript Status | Transcript Source | Chunk Count | Process Date | Error Message | Priority`

Set `Transcript Status = Pending` on any row you want ingested.

Every Google Sheets node in Workflows 1 and 4 currently has a **placeholder**
document ID (`YOUR_GOOGLE_SHEET_ID` / a `placeholder()` marker). Open each of
these 6 nodes and pick your real sheet from the document/sheet pickers:

- Workflow 1: `Read Pending Videos`, `Update Sheet - Success`, `Update Sheet - Failure`
- Workflow 4: `Find Failed Rows`, `Write Retry Status`, `Write Stale Status`

### Supabase setup
Run `supabase_schema.sql` (delivered alongside this guide) once in the
Supabase SQL editor. It creates the `videos` / `chunks` tables, the
`match_chunks()` RPC, indexes, and RLS policies.

### Link Workflow 3 → Workflow 2
Workflow 3's **"Retrieve Relevant Chunks"** node (Execute Sub-workflow) has a
placeholder workflow reference (`REPLACE_WITH_WORKFLOW_2_ID`). Open Workflow 3,
click that node, and pick **"2 - Knowledge Retrieval"** from the workflow
dropdown (or paste ID `0u1a55ytc4ZdO96D` directly) — n8n Cloud project IDs
aren't portable across instances, so this one link must be made manually.

### Attach the Error Handler
For Workflows 1, 3, and 4: open **Settings → Error Workflow** and select
**"0 - Error Handler"**. This is what makes the `onError: continueRegularOutput`
nodes' failures (and any unhandled node failure) show up in `#kb-alerts`
instead of silently vanishing.

### Environment variables / vars
No `.env` file is used — n8n Cloud manages secrets via credentials, not
environment variables. If you later self-host, the only environment-level
setting worth pinning is `N8N_DEFAULT_LOCALE` and your Postgres connection
pooling limits; everything else here is credential-based by design.

---

## 2. Testing Checklist

Work through this top-to-bottom before flipping the Schedule Triggers to *Active*.

- [ ] **Supabase schema** — run `supabase_schema.sql`; confirm `videos`, `chunks`,
      and `match_chunks()` exist (Supabase → Table Editor / Database → Functions).
- [ ] **Google Sheet** — create the `Video Queue` tab with all 11 columns; add
      1 test video row with `Transcript Status = Pending` and a real, publicly
      captioned YouTube URL.
- [ ] **Workflow 1 — manual test run**:
  - [ ] Run `Read Pending Videos` alone → confirm it returns your test row.
  - [ ] Run the full workflow once manually (▶ Test workflow). Watch:
    - `Extract Video ID` → `videoId` should be exactly 11 characters.
    - `Tier1 - Fetch Timedtext` → `data` should contain `<text ...>` XML for a
      typically-captioned video. If empty, confirm Tier 2 / Tier 3 fire correctly.
    - `Upsert Video Row` → should return a UUID `id`.
    - `Chunk Transcript` → should emit multiple items (one per chunk).
    - `Generate Chunk Embedding (Gemini)` → each item should have
      `embedding.values` as a 768-length array.
    - `Insert Chunk` → no SQL errors.
  - [ ] Check the Google Sheet row flips to `Transcript Status = Embedded`
        with a `Chunk Count` > 0.
  - [ ] In Supabase, `select count(*) from chunks where video_id = (select id from videos where video_id = 'YOUR_TEST_ID');`
        should match the Sheet's `Chunk Count`.
- [ ] **Force each fallback tier at least once**:
  - [ ] A video **with** standard captions → should land as `transcript_source = timedtext`.
  - [ ] A video where you temporarily break the Tier 1 URL (e.g. rename the field)
        → confirms Tier 2 fires.
  - [ ] A video with **no captions at all** → confirms Tier 3 (Apify) fires and
        `apify-whisper` or `apify-caption` is recorded.
  - [ ] A video URL that doesn't exist → confirms all 3 tiers fail gracefully and
        the Sheet shows `Failed: No transcript available` (not a crashed execution).
- [ ] **Workflow 2 — manual test**: use "Test workflow" with sample input
      `{ "question": "<something in your test video>", "matchCount": 5 }` and
      confirm `chunks` + `contextText` come back non-empty with a real
      `youtubeDeepLink`.
- [ ] **Workflow 3 — chat test**: open the hosted chat URL (Chat Trigger node →
      "Open Chat"), ask a question covered by your test video, and confirm the
      answer cites the video title + timestamp. Ask something **not** in any
      video and confirm it says it doesn't have that information (no hallucination).
- [ ] **Workflow 4 — dry run**: run manually once with an empty database — every
      branch should complete with 0 rows affected and no errors.
- [ ] **Error Handler** — temporarily break a credential on purpose, run
      Workflow 1, and confirm a Slack message lands in `#kb-alerts`.
- [ ] **Activate** Workflows 1, 3, and 4 (toggle Active in the top-right of each
      workflow). Workflow 2 does **not** need to be active — it is only ever
      invoked via Execute Sub-workflow.

---

## 3. Rollout Plan

1. **MVP (≈100 videos)**: run as-is. Expect ~$20–30/month, almost entirely the
   n8n Cloud subscription — the AI stack stays inside free tiers.
2. **500–2,000 videos**: watch Supabase storage (`Database → Usage`); consider
   adding a Cohere Rerank pass in Workflow 2 if retrieval precision degrades.
3. **10,000+ videos**: upgrade to Supabase Pro ($25/mo) once nearing 500 MB;
   switch the `ivfflat` index to `hnsw` (see `supabase_schema.sql` scaling notes).

---

## 4. Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---|---|---|
| Workflow 1 never picks up rows | Sheet's header row doesn't exactly match `Transcript Status`, or filter value isn't literally `Pending` | Check for trailing spaces / case in the header and cell value |
| `Tier1 - Fetch Timedtext` always empty | Video has no auto/manual captions, or YouTube changed the endpoint | Expected for some videos — confirm Tier 2/3 catch it. If **all** videos fail Tier 1, the endpoint may have changed; check n8n execution logs for the raw response |
| `Tier2 - Scrape Caption Manifest` errors with "fetch is not defined" | Some n8n Cloud sandbox versions restrict global `fetch` in Code nodes | Confirm your n8n Cloud plan/version supports it (Node 18+ sandbox); if not, replace this Code node with two chained HTTP Request nodes (fetch page → regex in a Set/Code step → fetch caption URL) |
| Apify branch always triggers (even for captioned videos) | Tier 1/2 IF conditions misconfigured, or `transcriptRaw` field name typo | Re-check `Has Tier1 Transcript?` / `Has Tier2 Transcript?` condition expressions match the exact field names emitted upstream |
| `Insert Chunk` fails with `operator does not exist: vector <=> unknown` type errors | `pgvector` extension not enabled, or embedding array wasn't cast to `::vector` | Re-run `create extension if not exists vector;`; confirm the query string includes `$7::vector` |
| `Insert Chunk` silently inserts 0 rows for a whole video | `on conflict (video_id, chunk_index) do nothing` — you re-ran the workflow on an already-embedded video | Expected/idempotent behavior; delete the chunk rows first if you want to force re-embedding, or use Workflow 4's stale-reprocessing branch |
| Gemini embedding/chat calls return 429 | Free-tier RPM exceeded | The batching option on `Generate Chunk Embedding` / `Embed Question` already serializes calls (1 per 1.2s); raise `batchInterval` if you still see 429s, or reduce `Loop Over Items` / Sheet batch size |
| Chatbot answers without citations or seems to hallucinate | `contextText` was empty because Workflow 2 returned 0 chunks | Check `match_chunks()` directly in the Supabase SQL editor with a known embedding; verify the question actually relates to indexed content |
| Workflow 3's sub-workflow call fails with "workflow not found" | The `Retrieve Relevant Chunks` node still has the placeholder workflow ID | Re-select Workflow 2 from the dropdown (see §1) |
| No Slack alerts on failure | Error Workflow not attached in Settings, or Slack credential/channel invite missing | Re-check Settings → Error Workflow on each workflow, and confirm the bot is invited to `#kb-alerts` |
| Supabase project "pauses" itself | Free-tier projects pause after 7 days of no activity | Workflow 1's own Schedule Trigger (every 15 min) keeps it active; if you disable Workflow 1 for testing, ping the DB some other way at least weekly |
| Maintenance workflow deletes more than expected | `Remove Duplicate Chunks` runs against a table without the `unique(video_id, chunk_index)` constraint | Re-run `supabase_schema.sql` to (re)create that constraint — with it in place this query should always affect 0 rows |

---

## 5. What Was *Not* Auto-Wired

n8n's workflow-creation API can bind **credentials** automatically where a
matching one already exists in your account, but it cannot know your Google
Sheet ID, your Apify actor's exact identifier, or which Gemini model alias is
enabled on your key. Before activating, double-check:

- The Apify actor ID/URL slug (`apify~youtube-transcript-scraper-captions-ai-fallback`)
  matches the exact actor you intend to use — Apify actor slugs can change if the
  publisher renames the actor.
- The Gemini model name in `generateAnswer` (`gemini-flash-lite-latest`) is
  still a valid alias for your account/region — Google occasionally renames
  model aliases; check https://ai.google.dev/gemini-api/docs/models if calls 404.
