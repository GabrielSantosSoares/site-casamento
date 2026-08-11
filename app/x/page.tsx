"use client";

import { FormEvent, useEffect, useState } from "react";
import { Dashboard, DashboardNoivos } from "../../componentes/DashboardNoivos";

const USUARIO_PRINCIPAL = "admin";
const CODIGO_API = "ADMINX";

export default function Administracao() {
  const [primeiro, setPrimeiro] = useState<boolean | null>(null);
  const [usuario, setUsuario] = useState(USUARIO_PRINCIPAL);
  const [senha, setSenha] = useState("");
  const [confirmacao, setConfirmacao] = useState("");
  const [chaveInicial, setChaveInicial] = useState("");
  const [aviso, setAviso] = useState("");
  const [carregando, setCarregando] = useState(true);
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);

  useEffect(() => {
    void (async () => {
      try {
        const resposta = await fetch("/api/convite", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          cache: "no-store",
          body: JSON.stringify({
            action: "estado_conta",
            usuario: USUARIO_PRINCIPAL,
          }),
        });
        const dados = await resposta.json();
        if (!resposta.ok) throw new Error(dados.error);
        setPrimeiro(!dados.estado.senha_criada);
      } catch {
        setPrimeiro(false);
        setAviso("Não foi possível verificar o acesso administrativo.");
      } finally {
        setCarregando(false);
      }
    })();
  }, []);

  async function enviar(evento: FormEvent) {
    evento.preventDefault();
    setAviso("");
    if (primeiro && senha !== confirmacao) {
      setAviso("As senhas digitadas não são iguais.");
      return;
    }

    const identificador = primeiro ? USUARIO_PRINCIPAL : usuario.trim();
    setCarregando(true);
    try {
      if (primeiro) {
        const respostaCriacao = await fetch("/api/convite", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action: "criar_senha_conta",
            usuario: USUARIO_PRINCIPAL,
            senha,
            chave_inicial: chaveInicial,
          }),
        });
        const dadosCriacao = await respostaCriacao.json();
        if (!respostaCriacao.ok) {
          if (respostaCriacao.status === 409) {
            setPrimeiro(false);
            setConfirmacao("");
            throw new Error("A senha já existe. Digite-a para entrar.");
          }
          throw new Error(
            dadosCriacao.error || "Não foi possível criar a senha.",
          );
        }
      }

      const respostaLogin = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "login_conta",
          usuario: identificador,
          senha,
        }),
      });
      const dadosLogin = await respostaLogin.json();
      if (!respostaLogin.ok)
        throw new Error(dadosLogin.error || "Senha incorreta.");

      const respostaDashboard = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "dashboard", codigo: CODIGO_API }),
      });
      const dadosDashboard = await respostaDashboard.json();
      if (!respostaDashboard.ok)
        throw new Error(
          dadosDashboard.error || "Não foi possível carregar o painel.",
        );
      setDashboard(dadosDashboard.dashboard);
    } catch (erro) {
      setAviso(
        erro instanceof Error ? erro.message : "Não foi possível acessar.",
      );
    } finally {
      setCarregando(false);
    }
  }

  async function sair() {
    await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "logout_conta" }),
    }).catch(() => undefined);
    window.location.assign("/");
  }

  if (dashboard)
    return (
      <main className="guest-app admin-route">
        <header className="guest-header">
          <span className="brand">
            <span className="monogram">
              <img src="/monograma-ga.png" alt="" />
            </span>
            <span>
              {dashboard.perfil === "admin"
                ? "Administração"
                : dashboard.perfil === "assessoria"
                  ? "Área da Assessoria"
                  : dashboard.perfil === "organizacao"
                    ? "Área da Organização"
                    : "Área dos Noivos"}
            </span>
          </span>
          <button className="exit" onClick={() => void sair()}>
            Sair
          </button>
        </header>
        <section className="guest-content">
          <DashboardNoivos dados={dashboard} codigo={CODIGO_API} />
        </section>
      </main>
    );

  return (
    <main className="admin-route">
      <section className="guest-content">
        <div className="panel couple-login">
          <p className="eyebrow">Área da organização</p>
          <h1>
            {primeiro === null
              ? "Verificando acesso"
              : primeiro
                ? "Crie a senha do administrador"
                : "Entrar no dashboard"}
          </h1>
          <p>
            {primeiro
              ? "O primeiro acesso é obrigatoriamente pelo administrador principal."
              : "Entre com o usuário ou o código de acesso da sua conta."}
          </p>
          {primeiro !== null && (
            <form onSubmit={enviar}>
              <label htmlFor="admin-user">Usuário ou código</label>
              <input
                id="admin-user"
                value={primeiro ? USUARIO_PRINCIPAL : usuario}
                onChange={(evento) =>
                  setUsuario(
                    evento.target.value
                      .replace(/[^A-Za-z0-9._-]/g, "")
                      .slice(0, 40),
                  )
                }
                minLength={3}
                maxLength={40}
                readOnly={Boolean(primeiro)}
                required
                autoComplete="username"
              />
              {primeiro && (
                <>
                  <label htmlFor="admin-setup-key">Chave inicial segura</label>
                  <input
                    id="admin-setup-key"
                    type="password"
                    value={chaveInicial}
                    onChange={(evento) => setChaveInicial(evento.target.value)}
                    required
                    autoComplete="off"
                  />
                  <small>
                    Use o valor configurado em ADMIN_SETUP_KEY no ambiente do
                    site.
                  </small>
                </>
              )}
              <label htmlFor="admin-password">Senha</label>
              <input
                id="admin-password"
                type="password"
                minLength={primeiro ? 8 : 6}
                maxLength={128}
                value={senha}
                onChange={(evento) => setSenha(evento.target.value)}
                required
                autoComplete={primeiro ? "new-password" : "current-password"}
              />
              {primeiro && (
                <>
                  <label htmlFor="admin-confirm">Confirmar senha</label>
                  <input
                    id="admin-confirm"
                    type="password"
                    minLength={8}
                    maxLength={128}
                    value={confirmacao}
                    onChange={(evento) => setConfirmacao(evento.target.value)}
                    required
                    autoComplete="new-password"
                  />
                </>
              )}
              {aviso && <p className="error">{aviso}</p>}
              <button className="primary" disabled={carregando}>
                {carregando
                  ? "Acessando..."
                  : primeiro
                    ? "Criar senha e entrar"
                    : "Entrar"}
              </button>
            </form>
          )}
        </div>
      </section>
    </main>
  );
}
