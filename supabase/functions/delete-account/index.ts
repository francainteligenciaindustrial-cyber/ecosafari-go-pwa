// =====================================================================
// EDGE FUNCTION: delete-account
// Exclui DE VERDADE a conta de quem está logado (exigência da Apple e do Google).
//  1) confirma quem chamou pelo token de login (ninguém apaga a conta de outra pessoa)
//  2) recusa contas da equipe de pousadas (precisam ser removidas pelo administrador)
//  3) apaga foto de perfil e capa do armazenamento
//  4) apaga o login (o perfil e os dados pessoais caem em cascata;
//     os avistamentos publicados ficam, sem nome — como informado nos Termos)
// Publicar:  supabase functions deploy delete-account
// (mantenha a verificação de JWT LIGADA — não use --no-verify-jwt aqui)
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return json({ ok: false, error: "sem login" }, 401);

    const admin = createClient(URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u, error: uErr } = await admin.auth.getUser(token);
    if (uErr || !u?.user) return json({ ok: false, error: "login inválido" }, 401);
    const uid = u.user.id;

    const { data: prof } = await admin.from("profiles").select("role").eq("id", uid).maybeSingle();
    if (prof && prof.role && prof.role !== "guest") {
      return json({ ok: false, error: "Contas da equipe devem ser removidas pelo administrador da pousada." }, 403);
    }

    for (const bucket of ["user-avatars", "user-covers"]) {
      const { data: files } = await admin.storage.from(bucket).list(uid, { limit: 100 });
      if (files && files.length) await admin.storage.from(bucket).remove(files.map((f) => `${uid}/${f.name}`));
    }

    const { error: delErr } = await admin.auth.admin.deleteUser(uid);
    if (delErr) throw new Error(delErr.message);
    return json({ ok: true });
  } catch (e) {
    console.error("delete-account:", (e as Error).message);
    return json({ ok: false, error: "erro ao excluir" }, 500);
  }
});
