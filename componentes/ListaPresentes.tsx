"use client";
import { useState } from "react";
export type Presente = {
  id: string;
  nome: string;
  descricao: string | null;
  imagens: string[];
  categoria_id?: string | null;
  categoria?: string | null;
  preco_centavos: number;
  quantidade_total: number | null;
  quantidade_assinada: number;
  quantidade_restante: number | null;
  quantidade_ilimitada?: boolean;
};
export type PresenteHistorico = {
  id: string;
  presente_id: string;
  presente: string;
  quantidade: number;
  meio: "fisico" | "mercado_pago";
  status: "pendente" | "confirmado" | "cancelado" | "rejeitado" | "reembolsado";
  pagamento_status: string | null;
  editavel: boolean;
  criado_em: string;
  aprovado_em: string | null;
  pode_tentar_pagamento?: boolean;
  checkout_url?: string | null;
  tentativa_pagamento_ate?: string | null;
  conciliacao_pagamento_ate?: string | null;
  tipo_pagamento?: string | null;
  boleto_vencimento?: string | null;
  status_entrega?: "Assinado" | "Entregue" | null;
  entregue_em?: string | null;
};
type ResultadoPagamento = {
  requer_cpf?: boolean;
  total_anterior?: number;
  valor_atual?: number;
  total_acumulado?: number;
  limite?: number;
};
type Props = {
  presentes: Presente[];
  carrinho: Record<string, number>;
  carregando: boolean;
  confirmado: boolean;
  mercadoPagoDisponivel: boolean;
  historico: PresenteHistorico[];
  aoAlterar: (id: string, q: number) => void;
  aoEscolherForma: (
    forma: "fisico" | "mercado_pago",
    dados?: { cpf?: string; aceite_privacidade?: boolean; mensagem?: string },
  ) => Promise<ResultadoPagamento | void>;
  aoAlterarFisico: (item: PresenteHistorico, quantidade: number) => void;
  aoCancelarFisico: (item: PresenteHistorico) => void;
};
const moeda = new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }),
  imagemPadrao = "/presente-padrao.png";
function ImagemPresente({ src, nome }: { src: string; nome: string }) {
  return (
    <img
      src={src}
      alt={`Imagem de ${nome}`}
      loading="lazy"
      onError={(e) => {
        if (!e.currentTarget.src.endsWith(imagemPadrao))
          e.currentTarget.src = imagemPadrao;
      }}
    />
  );
}
export function ListaPresentes({
  presentes,
  carrinho,
  carregando,
  confirmado,
  mercadoPagoDisponivel,
  historico,
  aoAlterar,
  aoEscolherForma,
  aoAlterarFisico,
  aoCancelarFisico,
}: Props) {
  const itens = Object.values(carrinho).reduce((t, q) => t + q, 0),
    [avisoAberto, setAvisoAberto] = useState(true),
    [formaAberta, setFormaAberta] = useState(false),
    [cpfAberto, setCpfAberto] = useState<ResultadoPagamento | null>(null),
    [cpf, setCpf] = useState(""),
    [aceite, setAceite] = useState(false),
    [mensagem, setMensagem] = useState(""),
    [enviandoCpf, setEnviandoCpf] = useState(false);
  async function escolherMercadoPago() {
    setFormaAberta(false);
    const resultado = await aoEscolherForma("mercado_pago", { mensagem });
    if (resultado?.requer_cpf) setCpfAberto(resultado);
  }
  async function confirmarCpf() {
    if (!aceite) return;
    setEnviandoCpf(true);
    const resultado = await aoEscolherForma("mercado_pago", {
      cpf,
      aceite_privacidade: true,
      mensagem,
    });
    setEnviandoCpf(false);
    if (!resultado?.requer_cpf) setCpfAberto(null);
  }
  return (
    <div className="panel gifts">
      {avisoAberto && (
        <div
          className="gift-modal-backdrop"
          role="presentation"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget) setAvisoAberto(false);
          }}
        >
          <section className="gift-modal" role="dialog" aria-modal="true">
            <span className="gift-modal-icon">♡</span>
            <p className="eyebrow">Antes de escolher</p>
            <h2>Sua presença é o que importa</h2>
            <p>
              Inicialmente tínhamos planejados não fazer uma lista, mas cedemos
              aos pedidos carinhos de alguns amigos e familiares. A lista é
              apenas uma sugestão para quem deseja nos presentear. O mais
              importante para nós é ter você conosco, celebrando esse novo
              começo! Sintam-se totalmente livres - a presença e o afeto de
              vocês no nosso grande dia já são o nosso melhor presente
            </p>
            <button className="primary" onClick={() => setAvisoAberto(false)}>
              Entendi
            </button>
          </section>
        </div>
      )}
      <p className="eyebrow">Lista de presentes</p>
      <h1>Escolha um carinho para a nossa nova história</h1>
      <p>Adicione ao carrinho e escolha a forma de presentear ao final.</p>
      {confirmado && (
        <div className="gift-success">
          ✓ Presente confirmado. Muito obrigado pelo carinho!
        </div>
      )}
      <div className="gift-grid">
        {presentes.map((p) => {
          const ilimitado = p.quantidade_ilimitada || p.quantidade_total === null,
            restante = p.quantidade_restante ?? 0,
            esgotado = !ilimitado && restante <= 0,
            q = carrinho[p.id] ?? 0,
            imagens = (p.imagens ?? []).filter(Boolean);
          return (
            <article key={p.id} className={esgotado ? "sold-out" : ""}>
              <div className="gift-gallery">
                {(imagens.length ? imagens : [imagemPadrao]).map((src, i) => (
                  <ImagemPresente key={`${src}-${i}`} src={src} nome={p.nome} />
                ))}
              </div>
              {imagens.length > 1 && (
                <small className="gallery-hint">
                  Deslize para ver mais imagens
                </small>
              )}
              {p.categoria && (
                <small className="gift-category">{p.categoria}</small>
              )}
              <h3>{p.nome}</h3>
              <p>{p.descricao}</p>
              <b>{moeda.format(p.preco_centavos / 100)}</b>
              <div className="gift-stats">
                <span>
                  <strong>{p.quantidade_assinada}</strong> assinados
                </span>
                <span>
                  <strong>{ilimitado ? "∞" : restante}</strong>{" "}
                  {ilimitado ? "sem limite" : "restantes"}
                </span>
              </div>
              {esgotado ? (
                <span className="sold-label">Esgotado</span>
              ) : (
                <div className="quantity-control">
                  <button
                    onClick={() => aoAlterar(p.id, Math.max(0, q - 1))}
                    disabled={q === 0}
                  >
                    −
                  </button>
                  <output>{q}</output>
                  <button
                    onClick={() =>
                      aoAlterar(p.id, Math.min(ilimitado ? 20 : restante, q + 1))
                    }
                    disabled={q >= (ilimitado ? 20 : restante)}
                  >
                    +
                  </button>
                </div>
              )}
            </article>
          );
        })}
      </div>
      <section className="public-signed">
        <h2>Presentes já assinados</h2>
        <div className="signed-list">
          {presentes
            .filter((p) => p.quantidade_assinada > 0)
            .map((p) => (
              <article key={p.id}>
                <div>
                  <b>{p.nome}</b>
                  <small>
                    {p.quantidade_assinada}{" "}
                    {p.quantidade_total === null
                      ? "assinados · sem limite"
                      : `de ${p.quantidade_total} assinados`}
                  </small>
                </div>
                <strong>{p.quantidade_assinada}</strong>
              </article>
            ))}
          {presentes.every((p) => p.quantidade_assinada === 0) && (
            <p>Ainda não há presentes assinados.</p>
          )}
        </div>
      </section>
      <section className="gift-history">
        <h2>Seu histórico de presentes</h2>
        <p>Presentes vinculados a este convite.</p>
        {historico.length ? (
          <div className="signed-list">
            {historico.map((item) => (
              <article key={item.id}>
                <div>
                  <b>{item.presente}</b>
                  <small>
                    {item.quantidade}{" "}
                    {item.quantidade === 1 ? "unidade" : "unidades"} ·{" "}
                    {item.meio === "fisico"
                      ? "Presente físico"
                      : "Mercado Pago"}{" "}
                    ·{" "}
                    {item.meio === "fisico" && item.status === "confirmado"
                      ? item.status_entrega === "Entregue"
                        ? `Entregue${item.entregue_em ? ` · ${new Date(item.entregue_em).toLocaleDateString("pt-BR")}` : ""}`
                        : "Assinado"
                      : item.status === "confirmado"
                      ? "Pagamento aprovado"
                      : item.status === "cancelado"
                        ? "Compra cancelada"
                        : item.status === "reembolsado"
                          ? "Pagamento reembolsado"
                      : item.status === "pendente"
                        ? item.tipo_pagamento === "ticket"
                          ? `Aguardando compensação do boleto${item.boleto_vencimento ? ` · vencimento ${new Date(item.boleto_vencimento).toLocaleDateString("pt-BR")}` : ""}`
                          : item.pode_tentar_pagamento
                            ? "Pagamento não concluído · nova tentativa disponível"
                            : "Pagamento em conciliação"
                        : "Pagamento não aprovado"}
                  </small>
                  {item.pode_tentar_pagamento && item.checkout_url && (
                    <div className="history-actions">
                      <button
                        className="secondary"
                        onClick={() => window.location.assign(item.checkout_url!)}
                      >
                        Tentar pagar novamente
                      </button>
                    </div>
                  )}
                  {item.editavel && (
                    <div className="history-actions">
                      <button
                        className="secondary"
                        onClick={() => {
                          const v = prompt(
                            "Nova quantidade:",
                            String(item.quantidade),
                          );
                          if (v) aoAlterarFisico(item, Number(v));
                        }}
                      >
                        Editar
                      </button>
                      <button
                        className="secondary danger"
                        onClick={() =>
                          confirm(`Cancelar ${item.presente}?`) &&
                          aoCancelarFisico(item)
                        }
                      >
                        Cancelar
                      </button>
                    </div>
                  )}
                </div>
                <strong>{item.quantidade}</strong>
              </article>
            ))}
          </div>
        ) : (
          <div className="empty-state">
            Você ainda não confirmou nenhum presente.
          </div>
        )}
      </section>
      <div className="cart-bar">
        <div>
          <span className="cart-icon">♡</span>
          <p>
            <b>Seu carrinho</b>
            <small>
              {itens} {itens === 1 ? "item selecionado" : "itens selecionados"}
            </small>
          </p>
        </div>
        <button
          className="primary"
          disabled={!itens || carregando}
          onClick={() => setFormaAberta(true)}
        >
          {carregando ? "Confirmando..." : "Confirmar presentes"}
        </button>
      </div>
      {formaAberta && (
        <div className="gift-modal-backdrop">
          <section
            className="gift-modal payment-choice"
            role="dialog"
            aria-modal="true"
          >
            <p className="eyebrow">Forma de presentear</p>
            <h2>Como você deseja dar o presente?</h2>
            <p>O presente ficará registrado no seu histórico.</p>
            <label htmlFor="gift-message">Mensagem para os noivos (opcional)</label>
            <textarea id="gift-message" maxLength={1000} value={mensagem} onChange={(e)=>setMensagem(e.target.value)} placeholder="Escreva uma mensagem para acompanhar o presente..." />
            <div className="payment-options">
              <button
                className="payment-option"
                onClick={() => {
                  setFormaAberta(false);
                  void aoEscolherForma("fisico", { mensagem });
                }}
              >
                <b>Dar o presente físico</b>
                <span>
                  Você entrega o item aos noivos. Esta escolha poderá ser
                  editada ou cancelada.
                </span>
              </button>
              {mercadoPagoDisponivel && (
                <button
                  className="payment-option mercado-pago"
                  onClick={() => void escolherMercadoPago()}
                >
                  <b>Doar o valor pelo Mercado Pago</b>
                  <span>
                    O item não será comprado pelo Mercado Pago. Você fará uma
                    doação aos noivos no valor correspondente ao presente
                    selecionado. Depois, será levado ao Checkout Pro e, após a
                    aprovação, a contribuição ficará registrada.
                  </span>
                </button>
              )}
            </div>
            {!mercadoPagoDisponivel && (
              <p className="form-note">
                O pagamento online ainda não está disponível.
              </p>
            )}
            <button className="secondary" onClick={() => setFormaAberta(false)}>
              Voltar ao carrinho
            </button>
          </section>
        </div>
      )}
      {cpfAberto && (
        <div className="gift-modal-backdrop">
          <section
            className="gift-modal cpf-consent"
            role="dialog"
            aria-modal="true"
            aria-labelledby="cpf-title"
          >
            <p className="eyebrow">Identificação do pagamento</p>
            <h2 id="cpf-title">Confirme seus dados</h2>
            <p>
              Como o total das suas contribuições alcança{" "}
              {moeda.format((cpfAberto.limite ?? 0) / 100)}, precisamos
              registrar seu CPF para controle fiscal.
            </p>
            <div className="cpf-total">
              <span>Contribuições aprovadas</span>
              <b>{moeda.format((cpfAberto.total_anterior ?? 0) / 100)}</b>
              <span>Pagamento atual</span>
              <b>{moeda.format((cpfAberto.valor_atual ?? 0) / 100)}</b>
              <span>Total após este pagamento</span>
              <strong>
                {moeda.format((cpfAberto.total_acumulado ?? 0) / 100)}
              </strong>
            </div>
            <label>
              CPF
              <input
                inputMode="numeric"
                autoComplete="off"
                value={cpf}
                onChange={(e) =>
                  setCpf(e.target.value.replace(/\D/g, "").slice(0, 11))
                }
                placeholder="000.000.000-00"
                aria-describedby="cpf-ajuda"
              />
            </label>
            <small id="cpf-ajuda">
              O CPF será protegido e usado somente para identificação e
              obrigações fiscais.
            </small>
            <label className="privacy-confirm">
              <input
                type="checkbox"
                checked={aceite}
                onChange={(e) => setAceite(e.target.checked)}
              />{" "}
              Li e concordo com a{" "}
              <a
                href="/politica-de-privacidade"
                target="_blank"
                rel="noreferrer"
              >
                Política de Privacidade
              </a>
              .
            </label>
            <div className="admin-actions">
              <button
                className="primary"
                disabled={enviandoCpf || cpf.length !== 11 || !aceite}
                onClick={() => void confirmarCpf()}
              >
                {enviandoCpf ? "Validando..." : "Confirmar e continuar"}
              </button>
              <button
                className="secondary"
                disabled={enviandoCpf}
                onClick={() => {
                  setCpfAberto(null);
                  setCpf("");
                  setAceite(false);
                }}
              >
                Cancelar
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
