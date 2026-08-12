"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import Link from "next/link";

type PessoaEntrada = {
  id: string;
  nome: string;
  codigo_individual: string;
  grupo: string;
  funcao: string | null;
  resposta: "sim" | "nao" | null;
  chegada_confirmada_em: string | null;
  chegada_confirmada_por_nome: string | null;
};

type ResumoEntrada = {
  confirmados: number;
  presentes: number;
  faltantes: number;
  presentes_lista: PessoaEntrada[];
  faltantes_lista: PessoaEntrada[];
};

export default function ControleEntrada() {
  const [codigo, setCodigo] = useState("");
  const [pessoa, setPessoa] = useState<PessoaEntrada | null>(null);
  const [resumo, setResumo] = useState<ResumoEntrada | null>(null);
  const [aviso, setAviso] = useState("");
  const [carregando, setCarregando] = useState(true);

  const carregarResumo = useCallback(async () => {
    const resposta = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "controle_entrada_resumo" }),
    });
    const dados = await resposta.json();
    if (!resposta.ok) throw new Error(dados.error || "Não foi possível carregar a lista.");
    setResumo(dados.resumo);
  }, []);

  useEffect(() => {
    let ativo = true;
    void fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "controle_entrada_resumo" }),
    })
      .then(async (resposta) => {
        const dados = await resposta.json();
        if (!resposta.ok)
          throw new Error(dados.error || "Não foi possível carregar a lista.");
        if (ativo) setResumo(dados.resumo);
      })
      .catch((erro) => {
        if (ativo)
          setAviso(
            erro instanceof Error ? erro.message : "Não foi possível carregar a lista.",
          );
      })
      .finally(() => {
        if (ativo) setCarregando(false);
      });
    return () => {
      ativo = false;
    };
  }, [carregarResumo]);

  async function buscar(evento: FormEvent) {
    evento.preventDefault();
    setCarregando(true);
    setAviso("");
    setPessoa(null);
    try {
      const resposta = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "buscar_controle_entrada",
          dados: { codigo },
        }),
      });
      const dados = await resposta.json();
      if (!resposta.ok) throw new Error(dados.error || "Código não encontrado.");
      setPessoa(dados.pessoa);
    } catch (erro) {
      setAviso(erro instanceof Error ? erro.message : "Não foi possível verificar o código.");
    } finally {
      setCarregando(false);
    }
  }

  async function confirmarChegada() {
    if (!pessoa) return;
    setCarregando(true);
    setAviso("");
    try {
      const resposta = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "confirmar_chegada",
          dados: { convidado_id: pessoa.id },
        }),
      });
      const dados = await resposta.json();
      if (!resposta.ok) throw new Error(dados.error || "Não foi possível confirmar a chegada.");
      setPessoa({ ...pessoa, chegada_confirmada_em: new Date().toISOString() });
      setAviso("Chegada confirmada com sucesso.");
      await carregarResumo();
    } catch (erro) {
      setAviso(erro instanceof Error ? erro.message : "Não foi possível confirmar a chegada.");
    } finally {
      setCarregando(false);
    }
  }

  return (
    <main className="door-control-page">
      <header className="door-control-header">
        <Link className="brand" href="/">
          <span className="monogram"><img src="/monograma-ga.png" alt="" /></span>
          <span>Gabriel &amp; Alanna</span>
        </Link>
        <Link className="secondary" href="/">Voltar ao site</Link>
      </header>
      <section className="door-control-shell">
        <div className="panel door-search-panel">
          <p className="eyebrow">Controle de entrada</p>
          <h1>Verificar convidado</h1>
          <p>Informe o código individual apresentado na entrada do evento.</p>
          <form onSubmit={buscar} className="door-search-form">
            <input
              value={codigo}
              onChange={(evento) =>
                setCodigo(
                  evento.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6),
                )
              }
              minLength={6}
              maxLength={6}
              placeholder="Código do convidado"
              autoComplete="off"
              required
              autoFocus
            />
            <button className="primary" disabled={carregando || codigo.length !== 6}>
              {carregando ? "Verificando..." : "Verificar"}
            </button>
          </form>
          {aviso && (
            <p className={aviso.includes("sucesso") ? "success-note" : "error"} role="status">
              {aviso}
            </p>
          )}
          {pessoa && (
            <article className="door-guest-card">
              <div>
                <p className="eyebrow">Resultado</p>
                <h2>{pessoa.nome}</h2>
                <p>{pessoa.grupo} · {pessoa.codigo_individual}</p>
                {pessoa.funcao && <p><b>{pessoa.funcao}</b></p>}
              </div>
              <div className="door-statuses">
                <span className={`door-badge ${pessoa.resposta === "sim" ? "confirmed" : "pending"}`}>
                  {pessoa.resposta === "sim"
                    ? "PRESENÇA CONFIRMADA"
                    : pessoa.resposta === "nao"
                      ? "NÃO COMPARECERÁ"
                      : "PRESENÇA NÃO CONFIRMADA"}
                </span>
                <span className={`door-badge ${pessoa.chegada_confirmada_em ? "arrived" : "pending"}`}>
                  {pessoa.chegada_confirmada_em ? "CHEGADA CONFIRMADA" : "AINDA NÃO CHEGOU"}
                </span>
              </div>
              {pessoa.chegada_confirmada_em ? (
                <small>
                  Chegada registrada em {new Date(pessoa.chegada_confirmada_em).toLocaleString("pt-BR")}
                  {pessoa.chegada_confirmada_por_nome
                    ? ` por ${pessoa.chegada_confirmada_por_nome}`
                    : ""}.
                </small>
              ) : (
                <button className="primary" onClick={() => void confirmarChegada()} disabled={carregando}>
                  Confirmar chegada
                </button>
              )}
            </article>
          )}
        </div>

        <aside className="panel door-summary">
          <p className="eyebrow">Acompanhamento</p>
          <h2>Entrada do evento</h2>
          {resumo ? (
            <>
              <div className="door-metrics">
                <span><b>{resumo.confirmados}</b> confirmados</span>
                <span><b>{resumo.presentes}</b> presentes</span>
                <span><b>{resumo.faltantes}</b> faltantes</span>
              </div>
              <details open>
                <summary>Presentes ({resumo.presentes})</summary>
                <div className="door-people-list">
                  {resumo.presentes_lista.map((item) => (
                    <span key={item.id}><b>{item.nome}</b><small>{item.codigo_individual}</small></span>
                  ))}
                  {!resumo.presentes_lista.length && <p>Nenhuma chegada confirmada.</p>}
                </div>
              </details>
              <details>
                <summary>Faltantes confirmados ({resumo.faltantes})</summary>
                <div className="door-people-list">
                  {resumo.faltantes_lista.map((item) => (
                    <span key={item.id}><b>{item.nome}</b><small>{item.codigo_individual}</small></span>
                  ))}
                  {!resumo.faltantes_lista.length && <p>Nenhum convidado confirmado está faltando.</p>}
                </div>
              </details>
            </>
          ) : (
            <p>{carregando ? "Carregando..." : "Faça login pela área da organização para acessar."}</p>
          )}
        </aside>
      </section>
    </main>
  );
}
