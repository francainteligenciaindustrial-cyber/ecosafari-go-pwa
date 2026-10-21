// =====================================================================
// EDGE FUNCTION: moderate-image
// Modera automaticamente fotos de perfil e de capa.
// Disparada por um Database Webhook em INSERT na tabela "storage.objects".
// 1) Ignora tudo que não seja dos buckets user-avatars e user-covers
// 2) Pede ao Google Cloud Vision (SafeSearch) para classificar a imagem
// 3) Se for adulta/violenta com alta probabilidade: apaga o arquivo e
//    limpa o endereço no perfil (a pessoa volta ao avatar/capa padrão)
//
// Segredos (Supabase > Edge Functions > Secrets):
//   GOOGLE_VISION_API_KEY — Google Cloud > APIs > Cloud Vision API > chave
// Se a chave não existir ou o Vision falhar, a imagem é mantida (falha aberta)
// e o botão "Denunciar" continua sendo a segunda linha de defesa.
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const VISION_KEY = Deno.env.get("GOOGLE_VISION_API_KEY");
const BUCKETS: Record<string, "avatar_url" | "cover_url"> = { "user-avatars": "avatar_url", "user-covers": "cover_url" };
const BAD = new Set(["LIKELY", "VERY_LIKELY"]);

function toBase64(buf: ArrayBuffer): string {
  let s = ""; const b = new Uint8Array(buf);
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}

Deno.serve(async (req) => {
  try {
    const { record } = await req.json();
    const bucket: string = record?.bucket_id, name: string = record?.name;
    const column = BUCKETS[bucket];
    if (!column || !name) return new Response("ignorado", { status: 200 });
    if (!VISION_KEY) return new Response("sem chave do Vision", { status: 200 });

    const { data: blob, error: dlErr } = await supabase.storage.from(bucket).download(name);
    if (dlErr || !blob) throw new Error("download: " + (dlErr?.message ?? "vazio"));
    const bytes = await blob.arrayBuffer();
    if (bytes.byteLength > 8_000_000) return new Response("grande demais", { status: 200 });

    const vr = await fetch(`https://vision.googleapis.com/v1/images:annotate?key=${VISION_KEY}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ requests: [{ image: { content: toBase64(bytes) }, features: [{ type: "SAFE_SEARCH_DETECTION" }] }] }),
    });
    if (!vr.ok) throw new Error("vision " + vr.status);
    const ss = (await vr.json()).responses?.[0]?.safeSearchAnnotation;
    if (!ss) return new Response("sem resultado", { status: 200 });

    const blocked = BAD.has(ss.adult) || BAD.has(ss.violence) || ss.racy === "VERY_LIKELY";
    if (!blocked) return new Response("ok", { status: 200 });

    await supabase.storage.from(bucket).remove([name]);
    // limpa o perfil que apontava para esse arquivo (o nome começa com o id do usuário)
    const uid = name.split("/")[0];
    await supabase.from("profiles").update({ [column]: null }).eq("id", uid).like(column, `%${name}%`);
    console.log("imagem removida:", bucket, name, JSON.stringify(ss));
    return new Response("removida", { status: 200 });
  } catch (e) {
    console.error("moderate-image:", (e as Error).message);
    return new Response("erro", { status: 200 }); // não reenviar em loop
  }
});
