// ============================================================
// RESPOND-MATCH EDGE FUNCTION
//
// Called by the frontend when a user taps "Let's meet!" or
// "Let's not" on the match screen.
//
// Flow:
//   pending  + user_b accepts → approved  (notify user_a)
//   approved + user_a accepts → confirmed (both go to radar)
//   any step + either passes  → rejected
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

  try {
    const { matchId, action } = await req.json();

    if (!matchId || !["accept", "pass", "met"].includes(action)) {
      return new Response(
        JSON.stringify({ error: "matchId and action ('accept' | 'pass' | 'met') required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Get the caller's auth ID from the JWT
    const authHeader = req.headers.get("Authorization")!;
    const token = authHeader.replace("Bearer ", "");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Verify the JWT and get the caller's identity
    const { data: { user: authUser }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authUser) {
      return new Response(
        JSON.stringify({ error: "Not authenticated" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Look up the caller's internal user ID
    const { data: caller } = await supabase
      .from("users")
      .select("id")
      .eq("auth_id", authUser.id)
      .single();

    if (!caller) {
      return new Response(
        JSON.stringify({ error: "User not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Fetch the match
    const { data: match } = await supabase
      .from("matches")
      .select("id, user_a, user_b, status")
      .eq("id", matchId)
      .single();

    if (!match) {
      return new Response(
        JSON.stringify({ error: "Match not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Verify the caller is part of this match
    const isUserA = match.user_a === caller.id;
    const isUserB = match.user_b === caller.id;
    if (!isUserA && !isUserB) {
      return new Response(
        JSON.stringify({ error: "Not your match" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Handle "met" — either user can mark from confirmed status
    if (action === "met") {
      if (match.status !== "confirmed") {
        return new Response(
          JSON.stringify({ error: "Match is not confirmed yet" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      await supabase
        .from("matches")
        .update({ status: "met" })
        .eq("id", matchId);

      return new Response(
        JSON.stringify({ status: "met" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Enforce turn order
    // pending  → user_b's turn
    // approved → user_a's turn
    if (match.status === "pending" && !isUserB) {
      return new Response(
        JSON.stringify({ error: "Not your turn" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    if (match.status === "approved" && !isUserA) {
      return new Response(
        JSON.stringify({ error: "Not your turn" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    if (!["pending", "approved"].includes(match.status)) {
      return new Response(
        JSON.stringify({ error: `Match already ${match.status}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Determine the other user
    const otherId = isUserA ? match.user_b : match.user_a;

    // Handle pass — always results in rejection
    if (action === "pass") {
      await supabase
        .from("matches")
        .update({ status: "rejected" })
        .eq("id", matchId);

      await supabase
        .from("interactions")
        .upsert(
          { actor_id: caller.id, target_id: otherId, action: "passed" },
          { onConflict: "actor_id,target_id" },
        );

      return new Response(
        JSON.stringify({ status: "rejected" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Handle accept
    const interactionAction = "liked";

    await supabase
      .from("interactions")
      .upsert(
        { actor_id: caller.id, target_id: otherId, action: interactionAction },
        { onConflict: "actor_id,target_id" },
      );

    if (match.status === "pending") {
      // user_b accepted → move to approved, notify user_a
      await supabase
        .from("matches")
        .update({ status: "approved" })
        .eq("id", matchId);

      // Send push to user_a
      const { data: userA } = await supabase
        .from("users")
        .select("expo_push_token, name")
        .eq("id", match.user_a)
        .single();

      const { data: userB } = await supabase
        .from("users")
        .select("name")
        .eq("id", match.user_b)
        .single();

      if (userA?.expo_push_token) {
        await fetch("https://exp.host/--/api/v2/push/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            to: userA.expo_push_token,
            title: "They want to meet you!",
            body: `${userB?.name ?? "Someone"} accepted — it's your call now`,
            data: { matchId, url: `/(app)/match/${matchId}` },
            sound: "default",
            priority: "high",
          }),
        });
      }

      return new Response(
        JSON.stringify({ status: "approved" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (match.status === "approved") {
      // user_a accepted → move to confirmed, both go to radar
      await supabase
        .from("matches")
        .update({ status: "confirmed" })
        .eq("id", matchId);

      // Send push to user_b so they know to open radar
      const { data: userB } = await supabase
        .from("users")
        .select("expo_push_token, name")
        .eq("id", match.user_b)
        .single();

      const { data: userA } = await supabase
        .from("users")
        .select("name")
        .eq("id", match.user_a)
        .single();

      if (userB?.expo_push_token) {
        await fetch("https://exp.host/--/api/v2/push/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            to: userB.expo_push_token,
            title: "It's a match!",
            body: `${userA?.name ?? "Someone"} wants to meet too — open your radar!`,
            data: { matchId, url: `/(app)/radar/${matchId}` },
            sound: "default",
            priority: "high",
          }),
        });
      }

      return new Response(
        JSON.stringify({ status: "confirmed" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Should not reach here
    return new Response(
      JSON.stringify({ error: "Unexpected state" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );

  } catch (err) {
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
