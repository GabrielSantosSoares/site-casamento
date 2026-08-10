import { NextRequest, NextResponse } from "next/server";
import { createDecipheriv, createHash } from "node:crypto";

const supabaseUrl = process.env.SUPABASE_URL;
const secret = process.env.SUPABASE_SECRET_KEY;
const encryptionKey = process.env.MP_CREDENTIAL_ENCRYPTION_KEY;

const headers = () => ({
  apikey: secret!,
  Authorization: `Bearer ${secret}`,
  "Content-Type": "application/json",
});

type NotificacaoPagamento = {
  type?: string;
  topic?: string;
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
  metadata?: { codigo_convidado?: string };
  payer?: {
    email?: string;
    first_name?: string;
    last_name?: string;
  };
};

async function registrarFalha(
  pagamentoId: string | null,
  etapa: string,
  mensagem: string,
) {
  if (!supabaseUrl || !secret) return;
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

async function corpoOpcional(request: NextRequest) {
  try {
    return (await request.json()) as NotificacaoPagamento;
  } catch {
    return {} as NotificacaoPagamento;
  }
}

function identificarNotificacao(
  request: NextRequest,
  body: NotificacaoPagamento,
) {
  const url = new URL(request.url);
  const tipo = body.type || body.topic || url.searchParams.get("type") || url.searchParams.get("topic");
  const id =
    body.data?.id ||
    url.searchParams.get("data.id") ||
    url.searchParams.get("id");
  return {
    tipo: String(tipo || "").toLowerCase(),
    id: id == null ? "" : String(id),
  };
}

function statusDaReserva(pagamento: PagamentoMercadoPago) {
  const boleto =
    pagamento.payment_type_id === "ticket" ||
    pagamento.payment_method_id === "bolbradesco" ||
    pagamento.payment_method_id === "pec";
  if (pagamento.status === "approved") return "confirmado";
  if (pagamento.status === "refunded") return "reembolsado";
  if (
    boleto &&
    (pagamento.status === "rejected" || pagamento.status === "cancelled")
  )
    return "cancelado";
  return "pendente";
}

export async function POST(request: NextRequest) {
  const body = await corpoOpcional(request);
  const notificacao = identificarNotificacao(request, body);
  if (notificacao.tipo !== "payment" || !notificacao.id)
    return NextResponse.json({ ok: true, ignorada: true });

  if (!supabaseUrl || !secret) {
    await registrarFalha(
      notificacao.id,
      "configuracao",
      "Supabase não configurado no ambiente do webhook",
    );
    return NextResponse.json({ ok: false }, { status: 503 });
  }

  try {
    const configResponse = await fetch(
      `${supabaseUrl}/rest/v1/integracoes_pagamento?id=eq.1&ativa=eq.true&select=access_token_cifrado`,
      { headers: headers(), cache: "no-store" },
    );
    if (!configResponse.ok) {
      await registrarFalha(
        notificacao.id,
        "configuracao",
        `Consulta da integração retornou HTTP ${configResponse.status}`,
      );
      return NextResponse.json({ ok: false }, { status: 503 });
    }
    const configuracao = (await configResponse.json())[0] as
      | { access_token_cifrado?: string }
      | undefined;
    if (!configuracao?.access_token_cifrado) {
      await registrarFalha(
        notificacao.id,
        "configuracao",
        "Integração do Mercado Pago ausente ou desativada",
      );
      return NextResponse.json({ ok: false }, { status: 503 });
    }

    const token = decrypt(configuracao.access_token_cifrado);
    const paymentResponse = await fetch(
      `https://api.mercadopago.com/v1/payments/${encodeURIComponent(notificacao.id)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        cache: "no-store",
      },
    );
    if (!paymentResponse.ok) {
      await registrarFalha(
        notificacao.id,
        "consulta_mercado_pago",
        `HTTP ${paymentResponse.status}`,
      );
      return NextResponse.json({ ok: false }, { status: 502 });
    }

    const pagamento = (await paymentResponse.json()) as PagamentoMercadoPago;
    if (!pagamento.external_reference) {
      await registrarFalha(
        String(pagamento.id),
        "referencia",
        "Pagamento sem external_reference",
      );
      return NextResponse.json({ ok: false }, { status: 422 });
    }

    const boleto =
      pagamento.payment_type_id === "ticket" ||
      pagamento.payment_method_id === "bolbradesco" ||
      pagamento.payment_method_id === "pec";
    const pagadorNome = [
      pagamento.payer?.first_name,
      pagamento.payer?.last_name,
    ]
      .filter(Boolean)
      .join(" ") || null;
    const codigoConvidado = String(
      pagamento.metadata?.codigo_convidado ?? "",
    )
      .trim()
      .toUpperCase();
    const dadosBase = {
      status: statusDaReserva(pagamento),
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
      aprovado_em:
        pagamento.status === "approved" ? new Date().toISOString() : null,
      reembolsado_em:
        pagamento.status === "refunded" ? new Date().toISOString() : null,
      atualizado_em: new Date().toISOString(),
    };

    const atualizar = (dados: Record<string, unknown>) =>
      fetch(
        `${supabaseUrl}/rest/v1/reservas_presentes?external_reference=eq.${encodeURIComponent(pagamento.external_reference!)}&meio=eq.mercado_pago`,
        {
          method: "PATCH",
          headers: { ...headers(), Prefer: "return=representation" },
          body: JSON.stringify(dados),
          cache: "no-store",
        },
      );

    let atualizado = await atualizar({
      ...dadosBase,
      ...(/^[A-Z0-9]{6}$/.test(codigoConvidado)
        ? { codigo_doador: codigoConvidado }
        : {}),
    });
    if (!atualizado.ok && /^[A-Z0-9]{6}$/.test(codigoConvidado)) {
      // Bancos que ainda não receberam a coluna codigo_doador continuam
      // processando o pagamento; a migração mais recente fará o backfill.
      atualizado = await atualizar(dadosBase);
    }
    if (!atualizado.ok) {
      await registrarFalha(
        String(pagamento.id),
        "atualizacao_banco",
        `HTTP ${atualizado.status}`,
      );
      return NextResponse.json({ ok: false }, { status: 500 });
    }

    const registros = (await atualizado.json()) as unknown[];
    if (!Array.isArray(registros) || registros.length === 0) {
      await registrarFalha(
        String(pagamento.id),
        "reserva_nao_encontrada",
        `Nenhuma reserva encontrada para external_reference ${pagamento.external_reference}`,
      );
      return NextResponse.json({ ok: false }, { status: 409 });
    }

    return NextResponse.json({ ok: true, atualizados: registros.length });
  } catch (erro) {
    await registrarFalha(
      notificacao.id,
      "processamento",
      erro instanceof Error ? erro.message : "Erro inesperado",
    );
    return NextResponse.json({ ok: false }, { status: 500 });
  }
}
