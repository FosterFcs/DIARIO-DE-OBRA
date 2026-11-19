// Supabase Edge Function: obra-ia
// IA do Foster Obras (Groq). A chave fica só aqui (secret GROQ_API_KEY, a mesma do Foster Orça).
//   ?acao=transcrever  → áudio do ditado → texto (Whisper)
//   ?acao=rdo          → relato do dia → campos do RDO (JSON)
//   ?acao=resumo       → RDOs da semana → resumo executivo (JSON)
// Só funciona para quem está logado e com teste/plano ativo na conta aberta (a própria ou a da equipe).
// Publicar:  supabase functions deploy obra-ia

const GROQ = "https://api.groq.com/openai/v1";
const MODELO = "llama-3.3-70b-versatile";
const MAX_TEXTO = 6000;
const MAX_DADOS = 32000;
const MAX_AUDIO = 8 * 1024 * 1024;

function cors(origin: string | null) {
  const env = (Deno.env.get("ALLOWED_ORIGINS") || "").split(",").map((s) => s.trim()).filter(Boolean);
  const allowed = env.length ? env : ["https://fosterfcs.github.io", "https://fostercalc.com.br", "https://www.fostercalc.com.br"];
  const ok = !!origin && (allowed.includes(origin) || /^https:\/\/[a-z0-9-]+\.fostercalc\.com\.br$/.test(origin));
  return {
    ok,
    headers: {
      "Access-Control-Allow-Origin": ok && origin ? origin : allowed[0],
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
      "Vary": "Origin",
    },
  };
}
const json = (body: unknown, status: number, headers: Record<string, string>) =>
  new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });

const SISTEMA_RDO = `Você organiza o relato de um engenheiro ou encarregado de obra no Brasil em um Relatório Diário de Obra (RDO).
Responda SOMENTE um objeto JSON com estas chaves:
- "efetivo": texto curto com a mão de obra do dia (ex: "3 pedreiros, 2 serventes, 1 eletricista"). "" se não falado.
- "atividades": serviços executados, uma linha por serviço, com local e quantidade quando ditos. "" se não falado.
- "materiais": materiais RECEBIDOS na obra (entregas, notas). "" se não falado.
- "ocorrencias": problemas, paralisações, chuva, acidentes, faltas. "" se não falado.
- "visitas": visitas e comunicações (cliente, fiscal, projetista). "" se não falado.
- "condicao": "praticavel", "parcial" ou "impraticavel" — só se o relato indicar; senão null.
- "servicos": lista de {"etapa_id", "percentual"} — use SOMENTE ids da lista "etapas" recebida, quando o relato disser quanto a etapa avançou ou que foi concluída. "percentual" é o avanço ACUMULADO da etapa (0 a 100) no fim do dia; se disserem "avançou 10%", some ao avanço atual informado. Se não houver informação clara, deixe [].
- "consumos": lista de {"material_id", "quantidade"} — materiais APLICADOS/consumidos no dia, SOMENTE ids da lista "materiais", quantidade na unidade do material. Se não houver, [].
- "equipamentos": lista de {"nome", "horas"} — equipamentos usados (horas = null se não ditas).
Regras: não invente nada que não foi dito; corrija a ortografia; use termos técnicos corretos de construção civil; escreva em português do Brasil.`;

const SISTEMA_RESUMO = `Você é assistente de um engenheiro civil responsável técnico no Brasil. Recebe os RDOs dos últimos 7 dias de uma obra (JSON) e as etapas do cronograma.
Escreva para o responsável técnico e o cliente. Responda SOMENTE um objeto JSON:
{"resumo": "3 a 5 frases sobre o andamento da semana",
 "destaques": ["serviços e avanços mais importantes"],
 "riscos": ["atrasos, ocorrências, paralisações, falta de registro, ressalvas do cliente — só o que os dados mostram"],
 "recomendacoes": ["ações práticas para a próxima semana"]}
Use apenas os dados recebidos; não invente números nem fatos. Listas com no máximo 6 itens. Português do Brasil, tom profissional e direto.`;

async function groqJSON(key: string, sistema: string, usuario: string) {
  const r = await fetch(`${GROQ}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: MODELO, temperature: 0.1, response_format: { type: "json_object" },
      messages: [{ role: "system", content: sistema }, { role: "user", content: usuario }],
    }),
  });
  if (!r.ok) throw new Error("falha na IA (" + r.status + ")");
  const j = await r.json();
  return JSON.parse(j.choices[0].message.content);
}

Deno.serve(async (req) => {
  const { ok, headers } = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (!ok) return json({ erro: "origem não permitida" }, 403, headers);
  if (req.method !== "POST") return json({ erro: "use POST" }, 405, headers);

  const key = Deno.env.get("GROQ_API_KEY");
  const acao = new URL(req.url).searchParams.get("acao");
  if (acao === "ping") return json({ ok: true, chave: !!key }, 200, headers);
  if (!key) return json({ erro: "IA não configurada" }, 500, headers);

  const auth = req.headers.get("authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({ erro: "login_necessario" }, 401, headers);

  try {
    let dono = "", form: FormData | null = null, corpo: Record<string, unknown> = {};
    if (acao === "transcrever") { form = await req.formData(); dono = String(form.get("dono_id") || ""); }
    else { corpo = await req.json(); dono = String(corpo.dono_id || ""); }
    if (!/^[0-9a-f-]{36}$/i.test(dono)) return json({ erro: "conta inválida" }, 400, headers);

    // plano ativo na conta aberta (o banco confere se o usuário é o titular ou da equipe)
    const sbUrl = Deno.env.get("SUPABASE_URL")!, sbAnon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const c = await fetch(`${sbUrl}/rest/v1/rpc/obra_conta_ativa_de`, {
      method: "POST", headers: { apikey: sbAnon, Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ p_uid: dono }),
    });
    if (!c.ok) return json({ erro: "login_necessario" }, 401, headers);
    if ((await c.json()) !== true) return json({ erro: "plano_inativo" }, 402, headers);

    if (acao === "transcrever") {
      const file = form!.get("file");
      if (!(file instanceof File)) return json({ erro: "áudio ausente" }, 400, headers);
      if (file.size > MAX_AUDIO) return json({ erro: "áudio muito longo (máx. 3 min)" }, 413, headers);
      const fd = new FormData();
      fd.append("file", file, file.name || "audio.webm");
      fd.append("model", "whisper-large-v3-turbo");
      fd.append("language", "pt");
      fd.append("prompt", "Relatório diário de obra: pedreiro, servente, alvenaria, reboco, contrapiso, concretagem, laje, viga, pilar, armação, fôrma, betoneira, bloco, cimento, areia, brita.");
      const r = await fetch(`${GROQ}/audio/transcriptions`, { method: "POST", headers: { Authorization: `Bearer ${key}` }, body: fd });
      if (!r.ok) return json({ erro: "falha na transcrição", status: r.status }, 502, headers);
      const j = await r.json();
      return json({ text: j.text || "" }, 200, headers);
    }

    if (acao === "rdo") {
      const texto = String(corpo.texto || "").trim();
      if (!texto) return json({ erro: "texto vazio" }, 400, headers);
      if (texto.length > MAX_TEXTO) return json({ erro: "texto muito longo" }, 413, headers);
      const etapas = Array.isArray(corpo.etapas) ? corpo.etapas.slice(0, 80) : [];
      const materiais = Array.isArray(corpo.materiais) ? corpo.materiais.slice(0, 150) : [];
      const usuario = JSON.stringify({ relato: texto, etapas, materiais });
      if (usuario.length > MAX_DADOS) return json({ erro: "dados grandes demais" }, 413, headers);
      return json(await groqJSON(key, SISTEMA_RDO, usuario), 200, headers);
    }

    if (acao === "resumo") {
      const dados = String(corpo.dados || "");
      if (!dados) return json({ erro: "sem dados" }, 400, headers);
      if (dados.length > MAX_DADOS) return json({ erro: "dados grandes demais" }, 413, headers);
      return json(await groqJSON(key, SISTEMA_RESUMO, dados), 200, headers);
    }

    return json({ erro: "ação inválida" }, 400, headers);
  } catch (e) {
    return json({ erro: "erro interno", detalhe: String(e).slice(0, 200) }, 500, headers);
  }
});
