// =====================================================================
// EDGE FUNCTION: verify-video
// Disparada por um Database Webhook em INSERT na tabela "sightings".
// 1) Baixa o vídeo do avistamento
// 2) Transcreve o áudio (OpenAI, modelo de transcrição)
// 3) Pede ao Claude para conferir se a pessoa disse nome, município e
//    data/hora, devolvendo um JSON
// 4) Grava o resultado com set_video_check() — o guia vê a checagem
//    pronta no Painel do Guia. A aprovação continua sendo humana.
//
// Segredos necessários (Supabase > Edge Functions > Secrets):
//   OPENAI_API_KEY      — platform.openai.com > API keys
//   ANTHROPIC_API_KEY   — console.anthropic.com > API keys (o mesmo da assistente)
// Limite: arquivos de até 25 MB (limite da API de transcrição).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const MODEL = Deno.env.get("VIDEO_CHECK_MODEL") ?? "claude-haiku-5-5";

async function finish(id: string, transcript: string | null, check: unknown, status: string) {
  const { error } = await supabase.rpc("set_video_check", {
    p_sighting_id: id, p_transcript: transcript, p_check: check, p_status: status,
  });
  if (error) console.error("set_video_check:", error.message);
}

Deno.serve(async (req) => {
  let sightingId = "";
  try {
    const { record } = await req.json();
    if (!record || !record.video_url) return new Response("sem vídeo", { status: 200 });
    sightingId = record.id;

    // 1) baixa o vídeo
    const videoRes = await fetch(record.video_url);
    if (!videoRes.ok) throw new Error("não foi possível baixar o vídeo");
    const blob = await videoRes.blob();
    if (blob.size > 25 * 1024 * 1024) {
      await finish(sightingId, null, { erro: "vídeo maior que 25 MB" }, "error");
      return new Response("grande demais", { status: 200 });
    }
    const ext = (blob.type.includes("webm") ? "webm" : "mp4");

    // 2) transcreve
    const form = new FormData();
    form.append("file", new File([blob], `video.${ext}`, { type: blob.type || "video/mp4" }));
    form.append("model", "whisper-1");
    form.append("language", "pt");
    const tr = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST", headers: { Authorization: `Bearer ${OPENAI_API_KEY}` }, body: form,
    });
    const trJson = await tr.json();
    if (!tr.ok) throw new Error("transcrição: " + JSON.stringify(trJson).slice(0, 300));
    const transcript: string = (trJson.text || "").trim();

    // 3) checa os critérios com o Claude
    const prompt = `Transcrição do áudio de um vídeo de avistamento de animal (em português, pode ter erros de transcrição):
"""${transcript}"""
A pessoa deveria dizer: o próprio nome, o município onde está, e a data e/ou hora do avistamento.
Data do registro no sistema: ${record.observed_at || record.created_at}.
Responda SOMENTE com um JSON neste formato, sem texto antes ou depois:
{"disse_nome": true/false, "nome": "nome dito ou null", "disse_municipio": true/false, "municipio": "município dito ou null", "disse_data_hora": true/false, "data_hora": "data/hora dita ou null", "observacao": "uma frase curta"}`;
    const ai = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: MODEL, max_tokens: 400, messages: [{ role: "user", content: prompt }] }),
    });
    const aiJson = await ai.json();
    if (!ai.ok) throw new Error("análise: " + JSON.stringify(aiJson).slice(0, 300));
    const text = (aiJson.content || []).map((b: { text?: string }) => b.text || "").join("");
    const match = text.match(/\{[\s\S]*\}/);
    const check = match ? JSON.parse(match[0]) : { erro: "resposta inválida", bruto: text.slice(0, 200) };

    await finish(sightingId, transcript, check, "done");
    return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
  } catch (err) {
    console.error(err);
    if (sightingId) await finish(sightingId, null, { erro: String(err).slice(0, 300) }, "error");
    return new Response(JSON.stringify({ error: String(err) }), { status: 200 });
  }
});
