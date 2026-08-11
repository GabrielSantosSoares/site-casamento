import type { Invitation, EventInfo } from "../componentes/AplicacaoCasamento";
import type { Presente } from "../componentes/ListaPresentes";

const EVENTO_PUBLICO_PADRAO: EventInfo = {
  data: "2026-10-03",
  hora: "18:30",
  cidade: "Candeias-BA",
  local_liberado: false,
  nome_espaco: "",
  endereco: "",
  link_maps: null,
};

export type AcessoInicial = {
  convite: Invitation;
  presentes: Presente[];
  mercado_pago_disponivel: boolean;
};

async function chamarRpc(nome: string, corpo: Record<string, unknown>) {
  const url = process.env.SUPABASE_URL;
  const chave = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !chave) return null;
  return fetch(`${url}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: { apikey: chave, "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
    cache: "no-store",
  }).catch(() => null);
}

export async function carregarEventoPublicoInicial(): Promise<EventInfo> {
  const resposta = await chamarRpc("evento_publico", {});
  if (!resposta?.ok) return EVENTO_PUBLICO_PADRAO;
  const evento = (await resposta.json().catch(() => null)) as Partial<EventInfo> | null;
  if (!evento) return EVENTO_PUBLICO_PADRAO;
  return {
    data: /^\d{4}-\d{2}-\d{2}$/.test(evento.data ?? "")
      ? (evento.data as string)
      : EVENTO_PUBLICO_PADRAO.data,
    hora: /^\d{2}:\d{2}$/.test(evento.hora ?? "")
      ? (evento.hora as string)
      : EVENTO_PUBLICO_PADRAO.hora,
    cidade: String(evento.cidade ?? EVENTO_PUBLICO_PADRAO.cidade).slice(0, 120),
    // Dados privados nunca entram no HTML da página pública, mesmo que uma
    // versão antiga da RPC ainda os devolva.
    local_liberado: false,
    nome_espaco: "",
    endereco: "",
    link_maps: null,
  };
}

async function mercadoPagoDisponivel() {
  const url = process.env.SUPABASE_URL;
  const chave = process.env.SUPABASE_SECRET_KEY;
  if (!url || !chave) return false;
  const resposta = await fetch(
    `${url}/rest/v1/integracoes_pagamento?id=eq.1&ativa=eq.true&select=id`,
    {
      headers: { apikey: chave, Authorization: `Bearer ${chave}` },
      cache: "no-store",
    },
  ).catch(() => null);
  return Boolean(resposta?.ok && ((await resposta.json()) as unknown[]).length);
}

export async function carregarAcessoInicial(
  codigoBruto: string,
): Promise<AcessoInicial | null> {
  const codigo = codigoBruto.trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(codigo)) return null;
  const [conviteResposta, presentesResposta, pagamentoDisponivel] =
    await Promise.all([
      chamarRpc("buscar_convite", { p_codigo: codigo }),
      chamarRpc("listar_presentes", {}),
      mercadoPagoDisponivel(),
    ]);
  if (!conviteResposta?.ok) return null;
  const convite = (await conviteResposta.json().catch(() => null)) as Invitation | null;
  if (!convite) return null;
  const presentes = presentesResposta?.ok
    ? ((await presentesResposta.json().catch(() => [])) as Presente[])
    : [];
  return {
    convite,
    presentes,
    mercado_pago_disponivel: pagamentoDisponivel,
  };
}

export async function codigoIndividualDoConviteUnitario(
  codigoGrupoBruto: string,
): Promise<string | null> {
  const codigoGrupo = codigoGrupoBruto.trim().toUpperCase();
  const url = process.env.SUPABASE_URL;
  const chave = process.env.SUPABASE_SECRET_KEY;
  if (!url || !chave || !/^[A-Z0-9]{6}$/.test(codigoGrupo)) return null;
  const headers = { apikey: chave, Authorization: `Bearer ${chave}` };
  const conviteResposta = await fetch(
    `${url}/rest/v1/convites?codigo=eq.${encodeURIComponent(codigoGrupo)}&ativo=eq.true&select=id&limit=1`,
    { headers, cache: "no-store" },
  ).catch(() => null);
  if (!conviteResposta?.ok) return null;
  const convites = (await conviteResposta.json()) as Array<{ id: string }>;
  if (!convites[0]?.id) return null;
  const pessoasResposta = await fetch(
    `${url}/rest/v1/convidados?convite_id=eq.${encodeURIComponent(convites[0].id)}&select=codigo_individual&order=ordem.asc,nome.asc&limit=2`,
    { headers, cache: "no-store" },
  ).catch(() => null);
  if (!pessoasResposta?.ok) return null;
  const pessoas = (await pessoasResposta.json()) as Array<{
    codigo_individual?: string | null;
  }>;
  if (pessoas.length !== 1) return null;
  const individual = String(pessoas[0].codigo_individual ?? "").toUpperCase();
  return /^[A-Z0-9]{6}$/.test(individual) && individual !== codigoGrupo
    ? individual
    : null;
}
