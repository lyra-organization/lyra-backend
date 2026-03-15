# Human — Backend

Supabase backend for a proximity-based dating app. PostgreSQL with PostGIS and pgvector handles geospatial matching and personality similarity scoring entirely in the database. Edge Functions act as thin API proxies to hide third-party keys.

## Stack

- **Database:** PostgreSQL 17 + PostGIS + pgvector
- **Edge Functions:** 4 Deno/TypeScript functions
- **Auth:** Supabase Auth (Apple Sign-In)
- **Realtime:** Supabase Broadcast (WebSocket for live radar)
- **AI:** Claude Haiku 4.5 (personality interview), OpenAI text-embedding-3-small (512-dim vectors)

## Architecture

```
Phone (Expo) <-> Supabase Edge Functions <-> Claude / OpenAI
                       |
                  PostgreSQL 17
              (PostGIS + pgvector)
```

The backend's primary job: when two users with compatible personality vectors are physically within 100 meters of each other, automatically connect them and notify both phones.

## Database Schema

### Tables

#### `users`
| Column | Type | Notes |
|---|---|---|
| `id` | `UUID` | PK |
| `auth_id` | `UUID` | FK -> `auth.users`, unique |
| `name` | `TEXT` | |
| `age` | `INTEGER` | |
| `gender` | `TEXT[]` | e.g. `['man']` |
| `show_me` | `TEXT[]` | Gender preference filter |
| `photo_url` | `TEXT` | Primary photo |
| `expo_push_token` | `TEXT` | For push notifications |
| `is_active` | `BOOLEAN` | Default `true` |

#### `profiles`
| Column | Type | Notes |
|---|---|---|
| `user_id` | `UUID` | FK -> `users`, unique |
| `transcript` | `JSONB` | Full interview message history |
| `summary` | `TEXT` | AI-generated 2-3 sentence bio |
| `traits` | `JSONB` | Complete raw profile JSON from Claude |
| `v_big_five` | `VECTOR(512)` | Big Five personality embedding |
| `v_values` | `VECTOR(512)` | Core values embedding |
| `v_interests` | `VECTOR(512)` | Interests embedding |
| `v_energy` | `VECTOR(512)` | Energy pattern embedding |
| `v_communication` | `VECTOR(512)` | Communication style embedding |
| `v_relationship` | `VECTOR(512)` | Relationship style embedding |
| `v_compatibility` | `VECTOR(512)` | Compatibility notes embedding |
| `v_keywords` | `VECTOR(512)` | Keywords embedding |

#### `locations`
| Column | Type | Notes |
|---|---|---|
| `user_id` | `UUID` | PK, FK -> `users` |
| `location` | `GEOGRAPHY(POINT, 4326)` | WGS-84 GPS point |
| `updated_at` | `TIMESTAMPTZ` | |

#### `matches`
| Column | Type | Notes |
|---|---|---|
| `id` | `UUID` | PK |
| `user_a` | `UUID` | User whose location triggered the match |
| `user_b` | `UUID` | User who gets notified first |
| `score` | `FLOAT` | Weighted similarity score (0-1) |
| `status` | `TEXT` | `pending` -> `approved` -> `confirmed` -> `met` (or `rejected`) |

#### `interactions`
| Column | Type | Notes |
|---|---|---|
| `actor_id` | `UUID` | FK -> `users` |
| `target_id` | `UUID` | FK -> `users` |
| `action` | `TEXT` | `liked`, `passed`, or `reported` |

### Indexes

| Index | Table | Type | Purpose |
|---|---|---|---|
| `idx_locations_geo` | `locations` | GIST | Accelerates `ST_DWithin` proximity queries |
| `idx_profiles_v_values` | `profiles` | HNSW (cosine) | ANN on values vectors |
| `idx_profiles_v_big_five` | `profiles` | HNSW (cosine) | ANN on Big Five vectors |
| `idx_interactions_pair` | `interactions` | UNIQUE BTREE | Prevents duplicate interactions |

## Matching Engine

A Postgres trigger (`trigger_match_check`) fires `AFTER INSERT OR UPDATE` on the `locations` table. On every GPS update:

1. Fetches the moving user's profile and preferences
2. Finds candidates within 100m using `ST_DWithin` (PostGIS)
3. Filters by bidirectional gender preferences (`&&` array overlap)
4. Excludes users with prior interactions or active pending matches
5. Computes a weighted similarity score across all 8 vector dimensions:

| Dimension | Weight |
|---|---|
| Values | 35% |
| Big Five | 25% |
| Interests | 15% |
| Energy | 5% |
| Communication | 5% |
| Relationship | 5% |
| Compatibility | 5% |
| Keywords | 5% |

6. Creates a match with the highest-scoring candidate (`LIMIT 1`, `ON CONFLICT DO NOTHING`)

## Edge Functions

### `/interview` — AI Interview Proxy

Streams Claude's response token-by-token as SSE. Hides the Anthropic API key.

- **Model:** `claude-haiku-4-5-20251001`, 2048 max tokens
- **System prompt:** Claude plays "Lyra", asks 6-8 personality questions, then emits a `<profile>` JSON block
- **Request:** `{ "messages": [...] }` (full conversation history)
- **Response:** SSE stream — `data: {"text": "..."}\n\n`, terminated by `data: [DONE]\n\n`

### `/embed` — Profile Embedding

Generates 8 separate 512-dim vectors from the personality profile and upserts to `profiles`.

- **Model:** OpenAI `text-embedding-3-small`, 512 dimensions
- **Request:** `{ "userId": "...", "profile": {...}, "transcript": [...] }`
- **Response:** `{ "success": true }`
- Uses `service_role` to bypass RLS

### `/send-push` — Match Notification

Triggered by a Supabase Database Webhook on `INSERT` to `matches`. Sends push notification to `user_b`.

- **Request (from webhook):** `{ "record": { "user_a": "...", "user_b": "...", "id": "..." } }`
- **Push payload:** Title "Someone compatible is nearby", body "{name} is near you right now", deep link to match screen

### `/respond-match` — Match State Machine

Handles accept/pass/met actions with turn-order enforcement.

- **Request:** `{ "matchId": "...", "action": "accept" | "pass" | "met" }`
- Requires JWT auth

**State transitions:**

| Current Status | Actor | Action | New Status | Notification |
|---|---|---|---|---|
| `pending` | `user_b` | accept | `approved` | user_a: "They want to meet you!" |
| `approved` | `user_a` | accept | `confirmed` | user_b: "It's a match!" + radar deep link |
| any | either | pass | `rejected` | none |
| `confirmed` | either | met | `met` | none |

## RLS Policies

| Table | Policy | Access |
|---|---|---|
| `users` | Own record only | ALL where `auth.uid() = auth_id` |
| `locations` | Own location only | ALL via auth_id subquery |
| `profiles` | Own profile only | SELECT via auth_id subquery |
| `matches` | Own matches only | SELECT where user is `user_a` or `user_b` |

## Realtime

`matches` and `locations` tables are published to Supabase Realtime for:
- **Match detection:** Frontend subscribes to `matches` changes for instant match notifications
- **Radar:** Frontend uses Supabase Broadcast channels (`radar:{matchId}`) to stream live GPS between matched users

## Environment Variables

Set via `npx supabase secrets set`:

| Variable | Used in | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | `/interview` | Claude API auth |
| `OPENAI_API_KEY` | `/embed` | OpenAI embeddings API auth |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by the Supabase runtime.

## Project Structure

```
lyra-backend/
└── supabase/
    ├── migrations/
    │   └── 20260314000000_init.sql     # Full schema, trigger, indexes, RLS
    └── functions/
        ├── interview/index.ts          # Claude streaming proxy
        ├── embed/index.ts              # 8-vector embedding + profile upsert
        ├── send-push/index.ts          # Webhook-triggered push notification
        └── respond-match/index.ts      # Match accept/pass/met state machine
```

## Deployment

```bash
# Link to Supabase project
npx supabase link --project-ref <project-id>

# Apply migrations
npx supabase db push

# Set secrets
npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... OPENAI_API_KEY=sk-...

# Deploy all edge functions
npx supabase functions deploy
```

### Manual Dashboard Setup

1. Enable **PostGIS** and **pgvector** extensions under Database -> Extensions
2. Configure **Apple Sign-In** under Authentication -> Providers -> Apple
3. Create a **Database Webhook** on `matches` table (`INSERT` event) pointing to the `/send-push` function URL
