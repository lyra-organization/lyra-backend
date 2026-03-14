# Lyra Backend — Implementation Plan

## Current State

### Backend (this repo) — Complete
- **Database schema** — 5 tables (users, profiles, locations, matches, interactions), spatial + vector indexes, automatic match trigger
- **`/interview`** — Edge Function that forwards chat messages to Claude and streams responses back word-by-word
- **`/embed`** — Edge Function that turns a personality description into a 512-number fingerprint via OpenAI
- **`/send-push`** — Edge Function that sends push notifications when matches happen (called automatically by a database webhook)
- **Match trigger** — SQL code living inside Postgres that automatically checks "is anyone compatible within 100m?" every time a location updates

### Frontend ([lyra-frontend](https://github.com/lyra-organization/lyra-frontend)) — Connected
- All 6 screens built with polished dark-theme UI and animations
- Apple Sign-In, AI interview streaming, background GPS, push notifications, live radar all wired up
- Match actions go through `/respond-match` Edge Function (not direct DB writes)

---

## Match Status Lifecycle

```
pending → approved → confirmed → met
            ↘         ↘
          rejected   rejected
```

| Status | What happened | Who acts next |
|--------|--------------|---------------|
| `pending` | Trigger found a match, user_b was notified | user_b decides |
| `approved` | user_b said "Let's meet!", user_a was notified | user_a decides |
| `confirmed` | user_a said "Let's meet!", both go to radar | Both on radar |
| `met` | Users found each other (< 3m on radar) | Done |
| `rejected` | Either user said "Let's not" | Done |

The trigger also blocks new matches when either user has a `pending`, `approved`, or `confirmed` match — so you can only have one active match at a time.

---

## Where Each Piece of Logic Runs

| Feature | Database | Edge Function | Phone |
|---|---|---|---|
| Interview conversation | | `/interview` (proxies to Claude) | Sends messages, displays streaming response |
| Profile + embedding | Stores profile + 8 vectors | `/embed` (calls OpenAI, writes to DB) | Sends profile JSON, waits for success |
| Background matching | **Trigger does everything** (geo + vector + gender filtering) | `/send-push` (sends notification to user_b) | Uploads GPS coordinates |
| Match decisions | Stores status updates + interactions | `/respond-match` (enforces turn order, notifies next user) | Calls Edge Function on button tap |
| Live radar | | | **Everything** — Broadcast channel, Haversine distance, UI |
| Met confirmation | Stores `met` status | `/respond-match` (action: `met`) | Fires on celebration (< 3m) |

---

## Deploying This Repo

```bash
# 1. Link to your Supabase project
npx supabase link --project-ref <your-project-id>

# 2. Run database migrations (creates tables + applies fixes)
npx supabase db push

# 3. Set API keys as secrets (never in code)
npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... OPENAI_API_KEY=sk-...

# 4. Deploy all Edge Functions
npx supabase functions deploy

# 5. In the Supabase Dashboard:
#    - Enable PostGIS and pgvector extensions (Database → Extensions)
#    - Set up Apple Sign-In (Authentication → Providers → Apple)
#    - Create DB webhook: table "matches", event INSERT → function "send-push"
```

---

## Repo Structure

```
lyra-backend/
├── supabase/
│   ├── migrations/
│   │   ├── 20260314000000_init.sql        ← 5 tables + indexes + RLS + match trigger
│   │   └── 20260314100000_fix_schema.sql  ← UNIQUE constraint, CASCADE, interactions RLS,
│   │                                         confirmed status, trigger fixes
│   └── functions/
│       ├── interview/index.ts             ← Claude streaming proxy
│       ├── embed/index.ts                 ← 8-vector embedding + profile save
│       ├── respond-match/index.ts         ← Accept/pass/met with turn-order enforcement
│       └── send-push/index.ts             ← Push notification sender (webhook-triggered)
└── README.md                              ← this file
```
