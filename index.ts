// Issues a LiveKit join token, but only to members of the call's conversation.
// Secrets: supabase secrets set LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken } from "npm:livekit-server-sdk@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return reply({ error: "unauthorized" }, 401);

  const { call_id } = await req.json().catch(() => ({}));
  // Row level security means this only returns calls in conversations the user belongs to.
  const { data: call } = await sb.from("calls").select("id, ended_at").eq("id", call_id).maybeSingle();
  if (!call || call.ended_at) return reply({ error: "call not available" }, 403);

  const { data: prof } = await sb.from("profiles").select("display_name").eq("id", user.id).maybeSingle();
  const at = new AccessToken(Deno.env.get("LIVEKIT_API_KEY")!, Deno.env.get("LIVEKIT_API_SECRET")!, {
    identity: user.id, name: prof?.display_name ?? "RedApp user", ttl: "2h",
  });
  at.addGrant({ roomJoin: true, room: call.id, canPublish: true, canSubscribe: true });
  return reply({ token: await at.toJwt() });
});
