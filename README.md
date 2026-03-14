# Lyra Backend — Implementation Plan

## Current State

### Backend (this repo) — Complete
- **Database schema** — 5 tables (users, profiles, locations, matches, interactions), spatial + vector indexes, automatic match trigger
- **`/interview`** — Edge Function that forwards chat messages to Claude and streams responses back word-by-word
- **`/embed`** — Edge Function that turns a personality description into a 512-number fingerprint via OpenAI
- **`/send-push`** — Edge Function that sends push notifications when matches happen (called automatically by a database webhook)
- **Match trigger** — SQL code living inside Postgres that automatically checks "is anyone compatible within 100m?" every time a location updates

### Frontend ([lyra-frontend](https://github.com/omarsaleh100/lyra-frontend)) — UI Only
- All 6 screens exist with polished dark-theme UI and animations
- Navigation between screens works
- Everything is hardcoded and simulated — no real backend connection

---

## What's Left to Build

### 1. Connect the phone to Supabase
**File:** `lib/supabase.ts` (frontend repo)

Right now the app has no backend connection. This file creates the Supabase client — the single object that lets the phone talk to the database, authentication, and Edge Functions. Every other piece depends on this existing first.

### 2. Real login
**File:** update `app/(auth)/login.tsx` (frontend repo)

The "Sign in with Apple" button currently just navigates to the next screen. It needs to actually authenticate through Apple, create a session in Supabase Auth, and create a row in the `users` table. Without this, the system has no way to know who's who.

### 3. Save onboarding data
**File:** update `app/(app)/onboarding.tsx` (frontend repo)

The name/age/gender/show-me form currently captures data in local state and throws it away when you tap "Next." It needs to write that data to the `users` table so the matching system knows who you are and what your gender preferences are.

### 4. Real AI interview
**Files:** `lib/interview.ts`, `lib/profileParser.ts`, update `app/(app)/interview.tsx` (frontend repo)

The interview screen currently shows 5 hardcoded questions with fake typing delays. It needs to:
- Send messages to our `/interview` Edge Function
- Read the streaming response (Server-Sent Events) and display Claude's words as they arrive
- Keep track of the full conversation history and send it with each request (Claude needs context)
- Detect when Claude outputs the `<profile>` tag (meaning the interview is over)
- Parse the JSON inside the `<profile>` tag
- Show the user "This is how Lyra sees you" with the AI-generated summary

**How streaming works:** The phone sends a POST request to `/interview` with all messages so far. The Edge Function opens a connection to Claude and starts receiving text chunks. Each chunk gets immediately forwarded to the phone as a Server-Sent Event. The phone assembles these chunks into a complete message in real time — so the user sees words appearing one by one, like someone typing.

### 5. Save the profile and create the personality fingerprint
**File:** `lib/embedding.ts` (frontend repo)

After the user sees their profile and taps "That's me!", the app needs to:
1. Take the structured profile JSON that Claude generated
2. Turn it into a natural language paragraph: *"A creative introvert who values authenticity and deep connection. Interested in hiking, photography, and philosophy..."*
3. Send that paragraph to our `/embed` Edge Function
4. Get back 512 numbers (the personality fingerprint)
5. Store the profile + fingerprint in the `profiles` table

This is the final step of onboarding. Once the embedding is stored, the user is "matchable" — the match trigger can now compare their fingerprint against others.

### 6. Background GPS tracking
**Files:** `lib/location.ts`, `tasks/locationTask.ts` (frontend repo)

The phone needs to quietly report GPS coordinates to the `locations` table while the app is in the background. This uses `expo-location` with low-power settings (cell tower/WiFi, not full GPS) to avoid killing the battery.

Every time a coordinate lands in the database, the match trigger we already built fires automatically. If someone compatible is within 100 meters, a match is created and a push notification is sent. The phone doesn't need to do anything — the database handles the entire matching pipeline on its own.

**Key details:**
- Uses `expo-task-manager` to run in the background
- Needs a separate Supabase client without auto-refresh (background tasks can't refresh auth tokens the normal way)
- Requires careful permission flow: ask for foreground location first, wait 600ms, then ask for background location (iOS race condition workaround)

### 7. Push notifications
**File:** `lib/notifications.ts` (frontend repo)

The phone needs to:
- Request notification permissions from the user
- Get an Expo push token (a unique address for this device)
- Store that token in the `users` table so `/send-push` knows where to deliver notifications
- Handle notification taps — when the user taps a "Someone nearby" notification, navigate to the match screen

### 8. Live radar
**Files:** `lib/radar.ts`, `hooks/useSmoothedDistance.ts`, update `app/(app)/radar/[id].tsx` (frontend repo)

The radar screen currently fakes a distance countdown from 100m to 0m. It needs to use real GPS:
- Both matched users join a Supabase Broadcast channel (a direct WebSocket connection, ~6ms latency)
- Each phone sends its GPS coordinates every 1-3 seconds
- Each phone listens for the other person's coordinates
- Distance is calculated on-device using the Haversine formula (one line of math)
- The distance is smoothed with a moving average so the number doesn't jump around
- The existing animated radar UI just needs real numbers fed into it — the animations are already built

---

## Where Each Piece of Logic Runs

| Feature | Database | Edge Function | Phone |
|---|---|---|---|
| Interview conversation | | `/interview` (proxies to Claude) | Sends messages, displays streaming response |
| Profile storage | Stores profile + embedding | `/embed` (proxies to OpenAI) | Parses Claude's output, calls embed, writes to DB |
| Background matching | **Trigger does everything** (geo + vector + gender filtering) | `/send-push` (sends notification) | Uploads GPS coordinates |
| Live radar | | | **Everything** — Broadcast channel, Haversine distance, UI |
| Push notifications | Stores device token | `/send-push` (delivers notification) | Registers for push, handles taps |

**Key insight:** The database does the hard work (spatial queries, vector similarity, automatic matching). The Edge Functions just hide API keys. The phone handles real-time stuff (radar) and orchestration (interview flow).

---

## Priority

**Items 1–5** make the onboarding + interview flow work end-to-end. This is the demo centerpiece — an AI conversation that generates a real personality profile and stores it. If only this works during the demo, you have a compelling product.

**Items 6–8** make the matching + radar flow work. If time runs out, these can be faked with Demo Mode (5 taps on the logo → pre-seeded match → simulated radar countdown). Judges see the same experience either way.

---

## Deploying This Repo

```bash
# 1. Link to your Supabase project
npx supabase link --project-ref <your-project-id>

# 2. Run the database migration (creates all tables + trigger)
npx supabase db push

# 3. Set API keys as secrets (never in code)
npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... OPENAI_API_KEY=sk-...

# 4. Deploy all three Edge Functions
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
│   │   └── 20260314000000_init.sql        ← 5 tables + indexes + match trigger
│   └── functions/
│       ├── interview/index.ts             ← Claude streaming proxy (~80 lines)
│       ├── embed/index.ts                 ← OpenAI embedding proxy (~30 lines)
│       └── send-push/index.ts             ← Push notification sender (~50 lines)
└── README.md                              ← this file
```
