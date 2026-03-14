// ============================================================
// MULTI-VECTOR EMBED & SAVE FUNCTION
//
// 1. Receives the full JSON profile from the phone.
// 2. Turns each of the 8 dimensions into a 512-dim vector.
// 3. Saves the profile + all 8 vectors directly to Postgres.
// ============================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { userId, profile, transcript } = await req.json();

    // 1. Prepare the 8 strings for embedding
    const fieldsToEmbed = [
      JSON.stringify(profile.big_five),
      profile.values.join(", "),
      profile.interests.join(", "),
      profile.energy_pattern,
      profile.communication_style,
      profile.relationship_style,
      profile.compatibility_notes,
      profile.keywords.join(", ")
    ];

    // 2. Call OpenAI Batch Embedding
    const openAIResponse = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${Deno.env.get("OPENAI_API_KEY")}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "text-embedding-3-small",
        input: fieldsToEmbed,
        dimensions: 512,
      }),
    });

    const openAIData = await openAIResponse.json();
    if (openAIData.error) throw new Error(openAIData.error.message);

    const vectors = openAIData.data.map((d: any) => d.embedding);

    // 3. Save directly to Database
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")! // Service role bypasses RLS
    );

    const { error } = await supabase
      .from("profiles")
      .upsert({
        user_id: userId,
        transcript: transcript,
        summary: profile.summary,
        traits: profile,
        v_big_five: vectors[0],
        v_values: vectors[1],
        v_interests: vectors[2],
        v_energy: vectors[3],
        v_communication: vectors[4],
        v_relationship: vectors[5],
        v_compatibility: vectors[6],
        v_keywords: vectors[7]
      });

    if (error) throw error;

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
