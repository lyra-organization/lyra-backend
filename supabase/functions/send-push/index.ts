// ============================================================
// SEND-PUSH EDGE FUNCTION
//
// This gets called automatically by a database webhook
// whenever a new match is created. It sends a push notification
// to the matched user's phone.
//
// Flow: match row inserted → webhook fires → this runs →
//       phone buzzes "Someone compatible is nearby"
// ============================================================

import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // The webhook sends us the new match row
  // It contains user_a (who triggered it) and user_b (who to notify)
  const { record } = await req.json();
  const { user_a, user_b, id: matchId } = record;

  // Connect to our database using the service role key
  // (this bypasses row-level security so we can read any user's push token)
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // Look up user_b's push token (the person being notified)
  const { data: userB } = await supabase
    .from("users")
    .select("expo_push_token, name")
    .eq("id", user_b)
    .single();

  // Also get user_a's name for the notification message
  const { data: userA } = await supabase
    .from("users")
    .select("name")
    .eq("id", user_a)
    .single();

  // If we don't have a push token, nothing to do
  if (!userB?.expo_push_token) {
    return new Response(JSON.stringify({ sent: false, reason: "no token" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Send the push notification via Expo's push service
  // Expo handles delivering it to Apple's APNs
  const pushResponse = await fetch("https://exp.host/--/api/v2/push/send", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      to: userB.expo_push_token,
      title: "Someone compatible is nearby",
      body: `${userA?.name ?? "Someone"} is near you right now`,
      data: { matchId, url: `/(app)/match/${matchId}` },
      sound: "default",
    }),
  });

  const result = await pushResponse.json();

  return new Response(JSON.stringify({ sent: true, result }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
