"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";

type PessoaEntrada = {
  id: string;
  nome: string;
  codigo_individual: string;
  grupo: string;
  codigo_grupo: string;
  funcao: string | null;
  resposta: "sim" | "nao" | null;
  chegada_confirmada_em: string | null;
  chegada_confirmada_por: string | null;
};

type Controle = {
  perfil: "admin" | "noivos" | "assessoria" | "organizacao";
  conta: { nome: string; funcao: string };
  total: number;
  presentes: number;
  faltantes: number;
  pessoas: PessoaEntrada[];
};

type Filtro = "todos" | "presentes" | "faltantes";

export function ControleEntrada() {
  const [controle, setControle] = useState<Controle | null>(null);
  const [busca, setBusca] = useState("");
  const [filtro, setFiltro] = useState<Filtro>("todos");
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState("");
  const [semAcesso, setSemAcesso] = useState(false);

  async function carregar(termo = "") {
    setCarregando(true);
    setErro("");
    const resposta = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      cache: "no-store",
      body: JSON.stringify({
        action: "controle_acesso",
        dados: { busca: termo.trim() },
      }),
    }).catch(() => null);
    if (!resposta) {
      setErro("Não foi possível conectar ao controle de entrada.");
      setCarregando(false);
      return;
    }
    const dados = await resposta.json();
    if (!resposta.ok) {
      setSemAcesso(resposta.status === 401 || resposta.status === 403);
      setErro(dados.error || "Não foi possível carregar a lista.");
      setCarregando(false);
      return;
    }
    setSemAcesso(false);
    setControle(dados.controle);
    setCarregando(false);
  }

  useEffect(() => {
    queueMicrotask(() => void carregar());
  }, []);

  async function pesquisar(evento: FormEvent) {
    evento.preventDefault();
    await carregar(busca);
  }

  async function confirmarChegada(pessoa: PessoaEntrada) {
    if (
      !window.confirm(
        `Confirmar a chegada de ${pessoa.nome}?${
          pessoa.resposta !== "sim"
            ? " A presença desta pessoa não estava confirmada anteriormente."
            : ""
        }`,
      )
    )
      return;
    setCarregando(true);
    setErro("");
    const resposta = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "confirmar_chegada",
        dados: { convidado_id: pessoa.id },
      }),
    });
    const dados = await resposta.json();
    if (!resposta.ok) {
      setErro(dados.error || "Não foi possível confirmar a chegada.");
      setCarregando(false);
      return;
    }
    await carregar(busca);
  }

  const pessoas = useMemo(() => {
    const lista = controle?.pessoas ?? [];
    if (filtro === "presentes")
      return lista.filter((pessoa) => pessoa.chegada_confirmada_em);
    if (filtro === "faltantes")
      return lista.filter(
        (pessoa) =>
          pessoa.resposta === "sim" && !pessoa.chegada_confirmada_em,
      );
    return lista;
  }, [controle, filtro]);

  if (semAcesso)
    return (
      <main className="checkin-page">
        <section className="panel checkin-login-required">
          <p className="eyebrow">Controle de entrada</p>
          <h1>Acesso reservado</h1>
          <p>{erro}</p>
          <a className="primary" href="/x">
            Entrar pela área da organização
          </a>
        </section>
      </main>
    );

  return (
    <main className="checkin-page">
      <header className="checkin-header">
        <a className="brand" href="/x">
          <span className="monogram">
            <img src="/monograma-ga.png" alt="" />
          </span>
          <span>Controle de entrada</span>
        </a>
        <a className="secondary" href="/x">
          Voltar ao painel
        </a>
      </header>

      <section className="checkin-shell">
        <div className="checkin-intro">
          <p className="eyebrow">Lista do evento</p>
          <h1>Chegada dos convidados</h1>
          <p>
            Digite o código individual ou pesquise pelo nome. Antes de confirmar
            a chegada, confira se a presença já havia sido confirmada.
          </p>
        </div>

        <form className="checkin-search" onSubmit={pesquisar}>
          <label htmlFor="codigo-ou-nome">Código ou nome do convidado</label>
          <div>
            <input
              id="codigo-ou-nome"
              value={busca}
              onChange={(evento) => setBusca(evento.target.value.slice(0, 150))}
              placeholder="Ex.: A1B2C3 ou Maria Silva"
              autoComplete="off"
            />
            <button className="primary" disabled={carregando}>
              {carregando ? "Consultando..." : "Verificar"}
            </button>
            {busca && (
              <button
                type="button"
                className="secondary"
                onClick={() => {
                  setBusca("");
                  void carregar();
                }}
              >
                Limpar
              </button>
            )}
          </div>
        </form>

        {controle && (
          <>
            <div className="checkin-summary">
              <button
                className={filtro === "todos" ? "selected" : ""}
                onClick={() => setFiltro("todos")}
              >
                <b>{controle.total}</b>
                <span>Todos</span>
              </button>
              <button
                className={filtro === "presentes" ? "selected" : ""}
                onClick={() => setFiltro("presentes")}
              >
                <b>{controle.presentes}</b>
                <span>Já chegaram</span>
              </button>
              <button
                className={filtro === "faltantes" ? "selected" : ""}
                onClick={() => setFiltro("faltantes")}
              >
                <b>{controle.faltantes}</b>
                <span>Faltantes confirmados</span>
              </button>
            </div>

            <div className="checkin-list" aria-live="polite">
              {pessoas.map((pessoa) => (
                <article key={pessoa.id}>
                  <div className="checkin-person">
                    <b>{pessoa.nome}</b>
                    <small>
                      Código {pessoa.codigo_individual} · {pessoa.grupo}
                      {pessoa.funcao ? ` · ${pessoa.funcao}` : ""}
                    </small>
                    <span
                      className={`rsvp-badge ${
                        pessoa.resposta === "sim"
                          ? "confirmed"
                          : pessoa.resposta === "nao"
                            ? "declined"
                            : "waiting"
                      }`}
                    >
                      {pessoa.resposta === "sim"
                        ? "PRESENÇA CONFIRMADA"
                        : pessoa.resposta === "nao"
                          ? "INFORMOU QUE NÃO IRÁ"
                          : "PRESENÇA NÃO CONFIRMADA"}
                    </span>
                  </div>
                  <div className="checkin-action">
                    {pessoa.chegada_confirmada_em ? (
                      <>
                        <span className="arrival-badge">✓ Chegada confirmada</span>
                        <small>
                          {new Date(
                            pessoa.chegada_confirmada_em,
                          ).toLocaleString("pt-BR")}
                          {pessoa.chegada_confirmada_por
                            ? ` · por ${pessoa.chegada_confirmada_por}`
                            : ""}
                        </small>
                      </>
                    ) : (
                      <button
                        className="primary"
                        disabled={carregando}
                        onClick={() => void confirmarChegada(pessoa)}
                      >
                        Confirmar chegada
                      </button>
                    )}
                  </div>
                </article>
              ))}
              {!carregando && !pessoas.length && (
                <div className="empty-state">
                  Nenhum convidado encontrado com esse filtro.
                </div>
              )}
            </div>
          </>
        )}
        {erro && (
          <p className="error" role="alert">
            {erro}
          </p>
        )}
      </section>
    </main>
  );
}
