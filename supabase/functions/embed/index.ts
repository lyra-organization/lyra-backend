// ============================================================
// EMBED EDGE FUNCTION
//
// Takes a text description of someone's personality and turns
// it into 512 numbers (a "vector") using OpenAI's embedding API.
//
// These numbers are a mathematical fingerprint of who someone is.
// Two people's fingerprints can be compared with simple math
// to see how compatible they are.
//
// Why does this exist? Same reason as /interview —
// to hide the OpenAI API key from the phone.
// ============================================================

import "@supabase/functions-js/edge-runtime.d.ts";

// Allow requests from the phone app
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  // Handle browser preflight checks (CORS)
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // The phone sends us a text string like:
  // "A creative introvert who values authenticity and loves hiking..."
  const { input } = await req.json();

  // Forward that text to OpenAI's embedding API
  // OpenAI turns it into 512 numbers
  const response = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("OPENAI_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "text-embedding-3-small",
      input,
      dimensions: 512, // 512 numbers per person
    }),
  });

  const data = await response.json();

  // Send the 512-number vector back to the phone
  return new Response(
    JSON.stringify({ embedding: data.data[0].embedding }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
