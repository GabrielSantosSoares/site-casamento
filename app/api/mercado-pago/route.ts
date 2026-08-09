import { NextRequest, NextResponse } from "next/server";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";

const supabaseUrl = process.env.SUPABASE_URL;
const secret = process.env.SUPABASE_SECRET_KEY;
const encryptionKey = process.env.MP_CREDENTIAL_ENCRYPTION_KEY;
const headers = () => ({
  apikey: secret!,
  Authorization: `Bearer ${secret}`,
  "Content-Type": "application/json",
});
const hash = (v: string) => createHash("sha256").update(v).digest("hex");
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function itensValidos(itens: Array<{ presente_id: string; quantidade: number }> | undefined) {
  if (!Array.isArray(itens) || itens.length < 1 || itens.length > 30) return null;
  const normalizados = itens.map((item) => ({
    presente_id: String(item.presente_id ?? "").trim().toLowerCase(),
    quantidade: Number(item.quantidade),
  }));
  if (
    normalizados.some(
      (item) =>
        !UUID.test(item.presente_id) ||
        !Number.isInteger(item.quantidade) ||
        item.quantidade < 1 ||
        item.quantidade > 20,
    ) ||
    new Set(normalizados.map((item) => item.presente_id)).size !== normalizados.length
  )
    return null;
  return normalizados;
}

async function rpc(name: string, body: Record<string, unknown>) {
  return fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
    cache: "no-store",
  });
}
async function table(path: string, init?: RequestInit) {
  return fetch(`${supabaseUrl}/rest/v1/${path}`, {
    ...init,
    headers: { ...headers(), ...(init?.headers ?? {}) },
    cache: "no-store",
  });
}
function key() {
  if (!encryptionKey) throw new Error("Chave de proteção não configurada");
  return createHash("sha256").update(encryptionKey).digest();
}
function encrypt(value: string) {
  const iv = randomBytes(12),
    cipher = createCipheriv("aes-256-gcm", key(), iv),
    data = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  return [
    iv.toString("base64"),
    cipher.getAuthTag().toString("base64"),
    data.toString("base64"),
  ].join(".");
}
function decrypt(value: string) {
  const [i, t, d] = value.split("."),
    dec = createDecipheriv("aes-256-gcm", key(), Buffer.from(i, "base64"));
  dec.setAuthTag(Buffer.from(t, "base64"));
  return Buffer.concat([
    dec.update(Buffer.from(d, "base64")),
    dec.final(),
  ]).toString("utf8");
}
async function isAdmin(request: NextRequest) {
  const token = request.cookies.get("sessao_noivos")?.value;
  if (!token) return false;
  const r = await rpc("dashboard_noivos", { p_token_hash: hash(token) });
  if (!r.ok) return false;
  const d = (await r.json()) as { perfil?: string } | null;
  return d?.perfil === "admin";
}
type ConfigPagamento = {
  ativa: boolean;
  public_key: string | null;
  access_token_cifrado: string | null;
  conta_id: string | null;
  conta_email: string | null;
  ambiente: string;
  verificada_em: string | null;
  recolher_cpf: boolean;
  cpf_valor_minimo_centavos: number;
};
type LinhaPagamento = {
  id: string;
  external_reference: string | null;
  pagamento_id: string | null;
  pagamento_status: string | null;
  status: string;
  pagador_nome: string | null;
  pagador_email: string | null;
  meio_pagamento_detalhe: string | null;
  valor_transacao: number | null;
  criado_em: string;
  aprovado_em: string | null;
  reembolso_id: string | null;
  reembolsado_em: string | null;
  quantidade: number;
  presentes?: { nome?: string } | null;
  convites?: { nome_familia?: string; codigo?: string } | null;
};
type PagamentoAgrupado = {
  id: string;
  pagamento_id: string | null;
  external_reference: string | null;
  status: string;
  pagamento_status: string | null;
  pagador_nome: string;
  pagador_email: string | null;
  meio_pagamento: string;
  valor: number | null;
  criado_em: string;
  aprovado_em: string | null;
  reembolso_id: string | null;
  reembolsado_em: string | null;
  convite_codigo: string | undefined;
  itens: Array<{ nome: string; quantidade: number }>;
};
async function config() {
  const r = await table("integracoes_pagamento?id=eq.1&select=*");
  if (!r.ok) return null;
  return (await r.json())[0] as ConfigPagamento | undefined;
}
async function accessToken() {
  const c = await config();
  return c?.ativa && c.access_token_cifrado
    ? decrypt(c.access_token_cifrado)
    : null;
}
async function mp(path: string, token: string, init?: RequestInit) {
  return fetch(`https://api.mercadopago.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
    cache: "no-store",
  });
}
function cpfValido(valor: string) {
  const cpf = valor.replace(/\D/g, "");
  if (!/^\d{11}$/.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false;
  const digito = (base: number) => {
    let soma = 0;
    for (let i = 0; i < base; i++) soma += Number(cpf[i]) * (base + 1 - i);
    const resto = (soma * 10) % 11;
    return resto === 10 ? 0 : resto;
  };
  return digito(9) === Number(cpf[9]) && digito(10) === Number(cpf[10]);
}
async function identidade(codigo: string) {
  const g = await table(
    `convidados?codigo_individual=eq.${codigo}&select=id,convite_id&limit=1`,
  );
  const pessoa = (await g.json())?.[0] as
    { id: string; convite_id: string } | undefined;
  if (pessoa)
    return {
      conviteId: pessoa.convite_id,
      doadorChave: `convite:${pessoa.convite_id}`,
    };
  const c = await table(`convites?codigo=eq.${codigo}&select=id&limit=1`);
  const convite = (await c.json())?.[0] as { id: string } | undefined;
  return convite
    ? { conviteId: convite.id, doadorChave: `convite:${convite.id}` }
    : null;
}
async function totalAprovado(doadorChave: string) {
  const r = await table(
    `reservas_presentes?doador_chave=eq.${encodeURIComponent(doadorChave)}&meio=eq.mercado_pago&status=eq.confirmado&select=external_reference,valor_transacao`,
  );
  if (!r.ok) return 0;
  const transacoes = new Map<string, number>();
  for (const x of (await r.json()) as Array<{
    external_reference: string | null;
    valor_transacao: number | null;
  }>) {
    const k = x.external_reference || String(transacoes.size);
    transacoes.set(
      k,
      Math.max(
        transacoes.get(k) ?? 0,
        Math.round(Number(x.valor_transacao ?? 0) * 100),
      ),
    );
  }
  return [...transacoes.values()].reduce((a, b) => a + b, 0);
}

export async function GET(request: NextRequest) {
  if (!supabaseUrl || !secret)
    return NextResponse.json(
      { error: "Supabase não configurado." },
      { status: 503 },
    );
  if (!(await isAdmin(request)))
    return NextResponse.json(
      { error: "Acesso exclusivo do administrador." },
      { status: 403 },
    );
  const c = await config();
  const tr = await table(
    "reservas_presentes?meio=eq.mercado_pago&select=id,external_reference,pagamento_id,pagamento_status,status,pagador_nome,pagador_email,meio_pagamento_detalhe,valor_transacao,criado_em,aprovado_em,reembolso_id,reembolsado_em,quantidade,presentes(nome),convites(nome_familia,codigo)&order=criado_em.desc",
  );
  const rows = tr.ok ? ((await tr.json()) as LinhaPagamento[]) : [];
  const agrupadas = new Map<string, PagamentoAgrupado>();
  for (const r of rows) {
    const id = String(r.pagamento_id || r.external_reference || r.id);
    const atual = agrupadas.get(id);
    const item = {
      nome: r.presentes?.nome || "Presente",
      quantidade: r.quantidade,
    };
    if (atual) {
      atual.itens.push(item);
      continue;
    }
    agrupadas.set(id, {
      id,
      pagamento_id: r.pagamento_id,
      external_reference: r.external_reference,
      status: r.status,
      pagamento_status: r.pagamento_status,
      pagador_nome:
        r.pagador_nome || r.convites?.nome_familia || "Não identificado",
      pagador_email: r.pagador_email,
      meio_pagamento: r.meio_pagamento_detalhe || "Mercado Pago",
      valor: r.valor_transacao,
      criado_em: r.criado_em,
      aprovado_em: r.aprovado_em,
      reembolso_id: r.reembolso_id,
      reembolsado_em: r.reembolsado_em,
      convite_codigo: r.convites?.codigo,
      itens: [item],
    });
  }
  return NextResponse.json({
    configuracao: c
      ? {
          ativa: c.ativa,
          public_key: c.public_key ?? "",
          access_token_mascarado: c.access_token_cifrado
            ? "••••••••••••••••"
            : "",
          conta_id: c.conta_id,
          conta_email: c.conta_email,
          ambiente: c.ambiente,
          verificada_em: c.verificada_em,
          recolher_cpf: Boolean(c.recolher_cpf),
          cpf_valor_minimo_centavos: Number(
            c.cpf_valor_minimo_centavos ?? 35000,
          ),
        }
      : null,
    pagamentos: [...agrupadas.values()],
  });
}

export async function POST(request: NextRequest) {
  if (!supabaseUrl || !secret)
    return NextResponse.json(
      { error: "Supabase não configurado." },
      { status: 503 },
    );
  const body = (await request.json()) as {
    action?: string;
    access_token?: string;
    public_key?: string;
    ambiente?: string;
    codigo?: string;
    itens?: Array<{ presente_id: string; quantidade: number }>;
    reserva_id?: string;
    quantidade?: number;
    pagamento_id?: string;
    recolher_cpf?: boolean;
    cpf_valor_minimo_centavos?: number;
    cpf?: string;
    aceite_privacidade?: boolean;
    mensagem?: string;
  };
  if (body.action === "salvar_credenciais") {
    if (!(await isAdmin(request)))
      return NextResponse.json(
        { error: "Acesso exclusivo do administrador." },
        { status: 403 },
      );
    const token = String(body.access_token ?? "").trim();
    if (!token)
      return NextResponse.json(
        { error: "Informe o Access Token." },
        { status: 400 },
      );
    const test = await mp("/users/me", token);
    if (!test.ok)
      return NextResponse.json(
        { error: "Credenciais recusadas pelo Mercado Pago." },
        { status: 400 },
      );
    const user = (await test.json()) as { id?: number; email?: string };
    const saved = await table("integracoes_pagamento?id=eq.1", {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        public_key: String(body.public_key ?? "").trim() || null,
        access_token_cifrado: encrypt(token),
        conta_id: String(user.id ?? ""),
        conta_email: user.email ?? null,
        ambiente: body.ambiente === "teste" ? "teste" : "producao",
        ativa: true,
        verificada_em: new Date().toISOString(),
        atualizado_em: new Date().toISOString(),
      }),
    });
    if (!saved.ok)
      return NextResponse.json(
        { error: "Execute a migração 022 antes de salvar." },
        { status: 502 },
      );
    return NextResponse.json({
      success: true,
      conta_id: user.id,
      conta_email: user.email,
    });
  }
  if (body.action === "desativar") {
    if (!(await isAdmin(request)))
      return NextResponse.json(
        { error: "Acesso exclusivo do administrador." },
        { status: 403 },
      );
    await table("integracoes_pagamento?id=eq.1", {
      method: "PATCH",
      body: JSON.stringify({
        ativa: false,
        atualizado_em: new Date().toISOString(),
      }),
    });
    return NextResponse.json({ success: true });
  }
  if (body.action === "configurar_cpf") {
    if (!(await isAdmin(request)))
      return NextResponse.json(
        { error: "Acesso exclusivo do administrador." },
        { status: 403 },
      );
    const minimo = Math.round(Number(body.cpf_valor_minimo_centavos));
    if (!Number.isInteger(minimo) || minimo < 1 || minimo > 100000000)
      return NextResponse.json(
        { error: "Informe um valor mínimo válido." },
        { status: 400 },
      );
    const r = await table("integracoes_pagamento?id=eq.1", {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        recolher_cpf: Boolean(body.recolher_cpf),
        cpf_valor_minimo_centavos: minimo,
        atualizado_em: new Date().toISOString(),
      }),
    });
    if (!r.ok)
      return NextResponse.json(
        { error: "Execute a migração 024 antes de salvar." },
        { status: 502 },
      );
    return NextResponse.json({ success: true });
  }
  if (body.action === "reembolsar") {
    if (!(await isAdmin(request)))
      return NextResponse.json(
        { error: "Acesso exclusivo do administrador." },
        { status: 403 },
      );
    const pagamentoId = String(body.pagamento_id ?? "").trim();
    if (!/^\d+$/.test(pagamentoId))
      return NextResponse.json(
        { error: "Pagamento inválido." },
        { status: 400 },
      );
    const existente = await table(
      `reservas_presentes?pagamento_id=eq.${pagamentoId}&meio=eq.mercado_pago&select=status,reembolso_id&limit=1`,
    );
    const reserva = (await existente.json())?.[0];
    if (!reserva || reserva.status !== "confirmado" || reserva.reembolso_id)
      return NextResponse.json(
        { error: "Este pagamento não está disponível para reembolso." },
        { status: 409 },
      );
    const token = await accessToken();
    if (!token)
      return NextResponse.json(
        { error: "A integração com o Mercado Pago não está ativa." },
        { status: 503 },
      );
    const idempotency = randomBytes(18).toString("hex"),
      refund = await mp(`/v1/payments/${pagamentoId}/refunds`, token, {
        method: "POST",
        headers: { "X-Idempotency-Key": idempotency },
        body: "{}",
      });
    const retorno = (await refund.json().catch(() => ({}))) as {
      id?: number | string;
      message?: string;
    };
    if (!refund.ok)
      return NextResponse.json(
        {
          error: retorno.message || "O Mercado Pago não autorizou o reembolso.",
        },
        { status: 502 },
      );
    const agora = new Date().toISOString();
    await table(
      `reservas_presentes?pagamento_id=eq.${pagamentoId}&meio=eq.mercado_pago`,
      {
        method: "PATCH",
        headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          status: "reembolsado",
          pagamento_status: "refunded",
          reembolso_id: String(retorno.id ?? idempotency),
          reembolsado_em: agora,
          atualizado_em: agora,
        }),
      },
    );
    return NextResponse.json({ success: true });
  }
  const codigo = String(body.codigo ?? "")
    .trim()
    .toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(codigo))
    return NextResponse.json({ error: "Código inválido." }, { status: 400 });
  if (body.action === "historico") {
    const r = await rpc("listar_historico_presentes", { p_codigo: codigo });
    return NextResponse.json({ historico: r.ok ? await r.json() : [] });
  }
  if (body.action === "fisico") {
    const itens = itensValidos(body.itens);
    if (!itens)
      return NextResponse.json(
        { error: "O carrinho contém itens inválidos ou repetidos." },
        { status: 400 },
      );
    const r = await rpc("registrar_presentes_fisicos", {
      p_codigo: codigo,
      p_itens: itens,
      p_mensagem: String(body.mensagem ?? "").slice(0,1000),
    });
    if (!r.ok || (await r.json()) !== true)
      return NextResponse.json(
        { error: "Algum item não está mais disponível." },
        { status: 409 },
      );
    return NextResponse.json({ success: true });
  }
  if (body.action === "alterar_fisico") {
    if (!UUID.test(String(body.reserva_id ?? "")))
      return NextResponse.json({ error: "Presente inválido." }, { status: 400 });
    const r = await rpc("alterar_presente_fisico", {
      p_codigo: codigo,
      p_reserva_id: body.reserva_id,
      p_quantidade: Math.floor(Number(body.quantidade)),
      p_cancelar: false,
    });
    if (!r.ok || (await r.json()) !== true)
      return NextResponse.json(
        { error: "Não foi possível alterar o presente." },
        { status: 409 },
      );
    return NextResponse.json({ success: true });
  }
  if (body.action === "cancelar_fisico") {
    if (!UUID.test(String(body.reserva_id ?? "")))
      return NextResponse.json({ error: "Presente inválido." }, { status: 400 });
    const r = await rpc("alterar_presente_fisico", {
      p_codigo: codigo,
      p_reserva_id: body.reserva_id,
      p_quantidade: 1,
      p_cancelar: true,
    });
    if (!r.ok || (await r.json()) !== true)
      return NextResponse.json(
        { error: "Não foi possível cancelar o presente." },
        { status: 409 },
      );
    return NextResponse.json({ success: true });
  }
  if (body.action === "criar_preferencia") {
    await rpc("expirar_reservas_pagamento", {});
    const c = await config(),
      token = await accessToken();
    if (!token || !c)
      return NextResponse.json(
        { error: "O pagamento pelo Mercado Pago não está disponível." },
        { status: 503 },
      );
    const itens = itensValidos(body.itens);
    if (!itens)
      return NextResponse.json(
        { error: "O carrinho contém itens inválidos ou repetidos." },
        { status: 400 },
      );
    const presentes = await table(
      `presentes?id=in.(${itens.map((i) => i.presente_id).join(",")})&ativo=eq.true&select=id,nome,preco_centavos`,
    );
    if (!presentes.ok)
      return NextResponse.json(
        { error: "Não foi possível consultar os presentes." },
        { status: 502 },
      );
    const catalogo = (await presentes.json()) as Array<{
      id: string;
      nome: string;
      preco_centavos: number;
    }>;
    if (catalogo.length !== itens.length)
      return NextResponse.json(
        { error: "Um presente não foi encontrado." },
        { status: 400 },
      );
    const id = await identidade(codigo);
    if (!id)
      return NextResponse.json(
        { error: "Convite não encontrado." },
        { status: 404 },
      );
    const valorAtual = itens.reduce((s, i) => {
        const p = catalogo.find((x) => x.id === i.presente_id)!;
        return s + p.preco_centavos * i.quantidade;
      }, 0),
      anterior = await totalAprovado(id.doadorChave),
      acumulado = anterior + valorAtual,
      limite = Math.max(1, Number(c.cpf_valor_minimo_centavos ?? 35000)),
      requerCpf = Boolean(c.recolher_cpf) && acumulado >= limite;
    const cpf = String(body.cpf ?? "").replace(/\D/g, "");
    if (requerCpf && (!body.aceite_privacidade || !cpfValido(cpf)))
      return NextResponse.json(
        {
          requer_cpf: true,
          total_anterior: anterior,
          valor_atual: valorAtual,
          total_acumulado: acumulado,
          limite,
          error: body.cpf
            ? "Informe um CPF válido e confirme a Política de Privacidade."
            : undefined,
        },
        { status: 428 },
      );
    const external = randomBytes(18).toString("hex"),
      origin = new URL(request.url).origin,
      criadoEm = new Date(),
      tentativaAte = new Date(criadoEm.getTime() + 15 * 60_000),
      conciliacaoAte = new Date(criadoEm.getTime() + 20 * 60_000);
    const pref = await mp("/checkout/preferences", token, {
      method: "POST",
      headers: { "X-Idempotency-Key": external },
      body: JSON.stringify({
        items: itens.map((i) => {
          const p = catalogo.find((x) => x.id === i.presente_id)!;
          return {
            id: p.id,
            title: `Presente de casamento: ${p.nome}`,
            quantity: i.quantidade,
            currency_id: "BRL",
            unit_price: p.preco_centavos / 100,
          };
        }),
        external_reference: external,
        ...(requerCpf ? { payer: { identification: { type: "CPF", number: cpf } } } : {}),
        back_urls: {
          success: `${origin}/c/${codigo}?pagamento=sucesso`,
          pending: `${origin}/c/${codigo}?pagamento=pendente`,
          failure: `${origin}/c/${codigo}?pagamento=falha`,
        },
        auto_return: "approved",
        expires: true,
        expiration_date_from: criadoEm.toISOString(),
        expiration_date_to: conciliacaoAte.toISOString(),
        notification_url: `${origin}/api/mercado-pago/webhook`,
      }),
    });
    if (!pref.ok)
      return NextResponse.json(
        { error: "O Mercado Pago não conseguiu iniciar o checkout." },
        { status: 502 },
      );
    const p = (await pref.json()) as {
      id: string;
      init_point: string;
      sandbox_init_point?: string;
    };
    const agora = criadoEm.toISOString(),
      checkoutUrl =
        c.ambiente === "teste" && p.sandbox_init_point
          ? p.sandbox_init_point
          : p.init_point;
    const reserva = await rpc("reservar_presentes_pagamento", {
      p_codigo: codigo,
      p_itens: itens,
      p_preferencia_id: p.id,
      p_external_reference: external,
      p_checkout_url: checkoutUrl,
      p_tentativa_pagamento_ate: tentativaAte.toISOString(),
      p_conciliacao_pagamento_ate: conciliacaoAte.toISOString(),
      p_doador_chave: id.doadorChave,
      p_cpf_cifrado: requerCpf ? encrypt(cpf) : null,
      p_cpf_consentimento_em: requerCpf ? agora : null,
      p_cpf_politica_versao: requerCpf ? "2026-07-31" : null,
      p_mensagem: String(body.mensagem ?? "").trim().slice(0, 1000),
    });
    if (!reserva.ok || (await reserva.json()) !== true)
      return NextResponse.json(
        {
          error:
            "Um dos presentes acabou de ser reservado por outra pessoa. Atualize a lista e tente novamente.",
        },
        { status: 409 },
      );
    return NextResponse.json({
      checkout_url: checkoutUrl,
    });
  }
  return NextResponse.json({ error: "Ação inválida." }, { status: 400 });
}
