import { NextRequest, NextResponse } from "next/server";
import { createDecipheriv, createHash } from "node:crypto";

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SECRET_KEY;
const encryptionKey = process.env.MP_CREDENTIAL_ENCRYPTION_KEY;

const headers = () => ({
  apikey: supabaseKey!,
  Authorization: `Bearer ${supabaseKey}`,
  "Content-Type": "application/json",
});

async function registrarFalha(
  pagamentoId: string | null,
  etapa: string,
  mensagem: string,
) {
  if (!supabaseUrl || !supabaseKey) return;
  await fetch(`${supabaseUrl}/rest/v1/falhas_webhook_pagamento`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({
      pagamento_id: pagamentoId,
      etapa,
      mensagem: mensagem.slice(0, 500),
    }),
  }).catch(() => null);
}

function decrypt(value: string) {
  if (!encryptionKey) throw new Error("Chave de proteção não configurada");
  const [iv, tag, data] = value.split(".");
  if (!iv || !tag || !data) throw new Error("Credencial protegida inválida");
  const key = createHash("sha256").update(encryptionKey).digest();
  const decipher = createDecipheriv(
    "aes-256-gcm",
    key,
    Buffer.from(iv, "base64"),
  );
  decipher.setAuthTag(Buffer.from(tag, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(data, "base64")),
    decipher.final(),
  ]).toString("utf8");
}

type Notificacao = {
  type?: string;
  action?: string;
  id?: string | number;
  data?: { id?: string | number };
};

type PagamentoMercadoPago = {
  id: number;
  status: string;
  external_reference?: string;
  transaction_amount?: number;
  payment_method_id?: string;
  payment_type_id?: string;
  date_of_expiration?: string;
  payer?: {
    email?: string;
    first_name?: string;
    last_name?: string;
  };
};

export async function POST(request: NextRequest) {
  let pagamentoId: string | null = null;
  try {
    if (!supabaseUrl || !supabaseKey || !encryptionKey)
      return NextResponse.json(
        { ok: false, error: "Integração não configurada." },
        { status: 503 },
      );

    const payload = (await request.json().catch(() => ({}))) as Notificacao;
    const parametros = new URL(request.url).searchParams;
    const tipo = payload.type ?? parametros.get("type") ?? undefined;
    const idRecebido =
      payload.data?.id ?? payload.id ?? parametros.get("data.id") ?? undefined;

    // Outros tipos de notificação não pertencem ao fluxo de pagamentos.
    if (tipo !== "payment" || idRecebido === undefined)
      return NextResponse.json({ ok: true, ignorada: true });

    pagamentoId = String(idRecebido);
    const configuracaoResponse = await fetch(
      `${supabaseUrl}/rest/v1/integracoes_pagamento?id=eq.1&ativa=eq.true&select=access_token_cifrado`,
      { headers: headers(), cache: "no-store" },
    );
    if (!configuracaoResponse.ok) {
      await registrarFalha(
        pagamentoId,
        "consulta_configuracao",
        `HTTP ${configuracaoResponse.status}`,
      );
      return NextResponse.json(
        { ok: false, error: "Configuração indisponível." },
        { status: 502 },
      );
    }

    const configuracao = (await configuracaoResponse.json())?.[0] as
      | { access_token_cifrado?: string }
      | undefined;
    if (!configuracao?.access_token_cifrado) {
      await registrarFalha(
        pagamentoId,
        "consulta_configuracao",
        "Integração ativa sem credencial disponível",
      );
      return NextResponse.json(
        { ok: false, error: "Integração indisponível." },
        { status: 503 },
      );
    }

    const token = decrypt(configuracao.access_token_cifrado);
    const pagamentoResponse = await fetch(
      `https://api.mercadopago.com/v1/payments/${encodeURIComponent(pagamentoId)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        cache: "no-store",
      },
    );
    if (!pagamentoResponse.ok) {
      await registrarFalha(
        pagamentoId,
        "consulta_mercado_pago",
        `HTTP ${pagamentoResponse.status}`,
      );
      return NextResponse.json(
        { ok: false, error: "Pagamento ainda não pôde ser consultado." },
        { status: 502 },
      );
    }

    const pagamento = (await pagamentoResponse.json()) as PagamentoMercadoPago;
    if (!pagamento.external_reference) {
      await registrarFalha(
        pagamentoId,
        "conciliacao",
        "Pagamento sem external_reference",
      );
      return NextResponse.json(
        { ok: false, error: "Pagamento sem referência de conciliação." },
        { status: 422 },
      );
    }

    const boleto =
      pagamento.payment_type_id === "ticket" ||
      pagamento.payment_method_id === "bolbradesco" ||
      pagamento.payment_method_id === "pec";
    const status =
      pagamento.status === "approved"
        ? "confirmado"
        : pagamento.status === "refunded"
          ? "reembolsado"
          : boleto &&
              (pagamento.status === "rejected" ||
                pagamento.status === "cancelled")
            ? "cancelado"
            : "pendente";
    const pagadorNome =
      [pagamento.payer?.first_name, pagamento.payer?.last_name]
        .filter(Boolean)
        .join(" ") || null;
    const agora = new Date().toISOString();
    const atualizacaoResponse = await fetch(
      `${supabaseUrl}/rest/v1/reservas_presentes?external_reference=eq.${encodeURIComponent(pagamento.external_reference)}&meio=eq.mercado_pago&select=id`,
      {
        method: "PATCH",
        headers: { ...headers(), Prefer: "return=representation" },
        body: JSON.stringify({
          status,
          pagamento_id: String(pagamento.id),
          pagamento_status: pagamento.status,
          pagador_nome: pagadorNome,
          pagador_email: pagamento.payer?.email ?? null,
          meio_pagamento_detalhe:
            pagamento.payment_method_id || pagamento.payment_type_id || null,
          tipo_pagamento: pagamento.payment_type_id ?? null,
          boleto_vencimento:
            boleto && pagamento.date_of_expiration
              ? pagamento.date_of_expiration
              : null,
          valor_transacao: pagamento.transaction_amount ?? null,
          aprovado_em: pagamento.status === "approved" ? agora : null,
          reembolsado_em: pagamento.status === "refunded" ? agora : null,
          atualizado_em: agora,
        }),
      },
    );

    if (!atualizacaoResponse.ok) {
      await registrarFalha(
        pagamentoId,
        "atualizacao_banco",
        `HTTP ${atualizacaoResponse.status}`,
      );
      return NextResponse.json(
        { ok: false, error: "Não foi possível atualizar o pagamento." },
        { status: 502 },
      );
    }

    const atualizados = (await atualizacaoResponse.json()) as Array<{
      id: string;
    }>;
    if (!Array.isArray(atualizados) || atualizados.length === 0) {
      await registrarFalha(
        pagamentoId,
        "conciliacao",
        `Nenhuma reserva encontrada para ${pagamento.external_reference}`,
      );
      return NextResponse.json(
        { ok: false, error: "Nenhuma reserva correspondente foi encontrada." },
        { status: 404 },
      );
    }

    return NextResponse.json({ ok: true, atualizados: atualizados.length });
  } catch (erro) {
    await registrarFalha(
      pagamentoId,
      "processamento",
      erro instanceof Error ? erro.message : "Erro inesperado",
    );
    return NextResponse.json(
      { ok: false, error: "Falha temporária ao processar a notificação." },
      { status: 500 },
    );
  }
}
