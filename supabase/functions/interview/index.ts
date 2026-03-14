// ============================================================
// INTERVIEW EDGE FUNCTION
//
// This is a middleman between the phone and Claude.
// The phone sends the chat history, we forward it to Claude,
// and stream Claude's response back word-by-word.
//
// Why does this exist? To hide the Anthropic API key.
// The phone can't safely store secrets.
// ============================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk";

// Allow requests from any origin (the phone app)
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// ============================================================
// THE PROFILE TEMPLATE
//
// This is what Claude is trying to fill out through the
// conversation. It keeps asking questions until it has enough
// information to complete every field confidently.
// ============================================================
const SYSTEM_PROMPT = `You are Lyra, a warm and perceptive interviewer helping someone share who they truly are. You are genuinely curious about them — not evaluating or judging.

## Your Goal

You have a profile template to fill. Have a natural conversation until you're confident you can complete every field accurately. You decide when you have enough — it might take 6 questions for an expressive person or 12 for someone more reserved.

## Profile Template

You need to gather enough to fill:
- summary: 2-3 sentence narrative of who they are
- openness: 0-1 (curious/creative vs conventional)
- conscientiousness: 0-1 (organized vs spontaneous)
- extraversion: 0-1 (outgoing vs reserved)
- agreeableness: 0-1 (cooperative vs competitive)
- neuroticism: 0-1 (sensitive vs resilient)
- values: 3-5 core values
- interests: 3-5 active interests
- energy_pattern: introvert | extrovert | ambivert
- communication_style: how they express themselves
- relationship_style: how they connect with people
- compatibility_notes: what kind of person they'd click with
- keywords: 5 words that capture them

## Rules

1. Ask ONE question at a time. Never stack questions.
2. Acknowledge what they said before asking the next thing.
3. Adapt based on their answers — don't follow a script.
4. Keep responses SHORT: 1-2 sentences of reflection, then your question.
5. Be casual and natural. Contractions are good. Jargon is bad.
6. If they give a short answer, gently probe deeper once.
7. Don't ask about job title, income, or physical appearance.
8. When you have enough information, wrap up warmly and output the completed profile.

## Output

When you're satisfied, say a brief closing message and then output the profile:

<profile>
{
  "summary": "...",
  "big_five": {
    "openness": 0.0,
    "conscientiousness": 0.0,
    "extraversion": 0.0,
    "agreeableness": 0.0,
    "neuroticism": 0.0
  },
  "values": [],
  "interests": [],
  "energy_pattern": "...",
  "communication_style": "...",
  "relationship_style": "...",
  "compatibility_notes": "...",
  "keywords": []
}
</profile>`;

// ============================================================
// THE SERVER
//
// Deno.serve is like Express or FastAPI — it listens for
// HTTP requests and runs this function for each one.
// ============================================================
Deno.serve(async (req) => {
  // Handle browser preflight checks (CORS)
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // The phone sends us the full conversation so far
  // e.g. [{ role: "user", content: "I love hiking" }, ...]
  const { messages } = await req.json();

  // Create a Claude client using our secret API key
  // (stored as an environment variable on Supabase, not in code)
  const client = new Anthropic({
    apiKey: Deno.env.get("ANTHROPIC_API_KEY")!,
  });

  // Set up a stream so we can send Claude's words back
  // to the phone one chunk at a time (like a live feed)
  const stream = new TransformStream();
  const writer = stream.writable.getWriter();
  const encoder = new TextEncoder();

  // Start streaming Claude's response in the background
  (async () => {
    try {
      // Ask Claude to respond, streaming word-by-word
      const claudeStream = client.messages.stream({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        messages,
      });

      // Each time Claude produces a chunk of text,
      // immediately send it to the phone
      for await (const event of claudeStream) {
        if (
          event.type === "content_block_delta" &&
          event.delta.type === "text_delta"
        ) {
          await writer.write(
            encoder.encode(
              `data: ${JSON.stringify({ text: event.delta.text })}\n\n`
            )
          );
        }
      }

      // Tell the phone "that's everything"
      await writer.write(encoder.encode("data: [DONE]\n\n"));
    } catch (err) {
      // If something goes wrong, send the error to the phone
      await writer.write(
        encoder.encode(
          `data: ${JSON.stringify({ error: String(err) })}\n\n`
        )
      );
    } finally {
      await writer.close();
    }
  })();

  // Return the stream as a Server-Sent Events (SSE) response
  // The phone reads this like a live text feed
  return new Response(stream.readable, {
    headers: {
      ...corsHeaders,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    },
  });
});
