// =====================================================================
// EDGE FUNCTION: send-web-push
// Disparada por um Database Webhook em INSERT na tabela "alerts".
// Envia o alerta como notificação para todos os aparelhos em que o
// usuário ativou "Alertas no celular" (app instalado na tela inicial).
//
// Segredos necessários:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY  — gere com: npx web-push generate-vapid-keys
//   VAPID_SUBJECT                        — ex.: mailto:contato@ecosafarigo.com
// A chave PÚBLICA também vai no app (CONFIG.webPushPublicKey).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:contato@ecosafarigo.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  try {
    const { record: alert } = await req.json();
    if (!alert) return new Response("sem alerta", { status: 200 });

    const { data: subs, error } = await supabase
      .from("web_push_subscriptions").select("id, endpoint, p256dh, auth").eq("user_id", alert.user_id);
    if (error) throw error;

    const payload = JSON.stringify({ title: alert.title, body: alert.body, tag: "alert-" + alert.id, url: "./index.html" });
    let sent = 0, removed = 0;
    for (const s of subs || []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { // aparelho desinstalou ou revogou
          await supabase.from("web_push_subscriptions").delete().eq("id", s.id);
          removed++;
        } else console.error("push falhou:", code, String(e).slice(0, 200));
      }
    }
    return new Response(JSON.stringify({ sent, removed }), { headers: { "Content-Type": "application/json" } });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
