"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import {
  ListaPresentes,
  Presente,
  PresenteHistorico,
} from "../componentes/ListaPresentes";
import { ManualFuncao } from "../componentes/ManualFuncao";
import { Dashboard, DashboardNoivos } from "../componentes/DashboardNoivos";
import {
  resolverAcessoFuncoes,
  rotuloResumoFuncao,
} from "../lib/funcoes";
import QRCode from "qrcode";

type View =
  | "inicio"
  | "convite"
  | "presenca"
  | "presentes"
  | "cortejo"
  | "noivos";
type RetornoPagamento = {
  status: "sucesso" | "pendente" | "falha";
  mensagem: string;
};
type Guest = {
  id: string;
  nome: string;
  codigo_individual: string;
  pode_gerenciar: boolean;
  funcao: string | null;
  status: "sim" | "nao" | null;
  crianca: boolean;
  idade: number | null;
};
type Manager = { id: string; nome: string; funcao: string | null };
type Instruction = { icone: string; titulo: string; texto: string };
export type EventInfo = {
  data: string;
  hora: string;
  cidade: string;
  local_liberado: boolean;
  nome_espaco: string;
  endereco: string;
  link_maps: string | null;
};
type Invitation = {
  codigo: string;
  codigo_conjunto: string;
  nome_familia: string;
  funcao_cortejo: string | null;
  instrucoes_cortejo: Instruction[];
  convidados: Guest[];
  nivel_acesso: number;
  perfil_acesso: "convidado" | "cortejo" | "noivos" | "assessoria" | "admin";
  manuais: string[];
  senha_criada: boolean;
  exige_troca_senha?: boolean;
  pode_gerenciar: boolean;
  responsaveis: Manager[];
  expira_em: string | null;
  expirado: boolean;
  prazo_vencido: boolean;
  sem_expiracao: boolean;
  idade_limite_crianca: number;
  criancas_adicionais_restantes: number;
  evento: EventInfo;
};

const EVENTO_PADRAO: EventInfo = {
  data: "2026-10-03",
  hora: "18:30",
  cidade: "Candeias-BA",
  local_liberado: false,
  nome_espaco: "Espaço Brunus",
  endereco: "Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000",
  link_maps: null,
};

function partesEvento(evento?: EventInfo | null) {
  const data = /^\d{4}-\d{2}-\d{2}$/.test(evento?.data ?? "")
    ? evento!.data
    : EVENTO_PADRAO.data;
  const instante = new Date(`${data}T12:00:00`);
  const mes = new Intl.DateTimeFormat("pt-BR", { month: "long" }).format(instante);
  const diaSemana = new Intl.DateTimeFormat("pt-BR", { weekday: "long" }).format(instante);
  const horaBruta = evento?.hora || EVENTO_PADRAO.hora;
  const hora = /^\d{2}:\d{2}$/.test(horaBruta)
    ? horaBruta.replace(":", "h")
    : horaBruta;
  return {
    dia: new Intl.DateTimeFormat("pt-BR", { day: "2-digit" }).format(instante),
    mes,
    mesCurto: mes.slice(0, 3).toLocaleUpperCase("pt-BR"),
    ano: String(instante.getFullYear()),
    diaSemana: diaSemana.charAt(0).toLocaleUpperCase("pt-BR") + diaSemana.slice(1),
    hora,
    dataExtenso: new Intl.DateTimeFormat("pt-BR", {
      day: "2-digit",
      month: "long",
      year: "numeric",
    }).format(instante),
    dataNumerica: new Intl.DateTimeFormat("pt-BR").format(instante),
  };
}

function conviteTemPapel(convite: Invitation | null) {
  if (!convite) return false;
  return resolverAcessoFuncoes(
    convite.codigo,
    convite.convidados,
    convite.pode_gerenciar,
  ).temFuncao;
}

function retornoPagamentoAtual(): RetornoPagamento | null {
  const status = new URLSearchParams(window.location.search).get("pagamento");
  if (status === "sucesso")
    return {
      status,
      mensagem:
        "Retorno recebido. O pagamento aparecerá no histórico assim que o Mercado Pago concluir a confirmação.",
    };
  if (status === "pendente")
    return {
      status,
      mensagem:
        "O pagamento está em processamento. Você continua no seu convite e pode acompanhar a atualização aqui.",
    };
  if (status === "falha")
    return {
      status,
      mensagem:
        "O pagamento não foi concluído. Seu convite continua aberto e você pode tentar novamente.",
    };
  return null;
}

export function SiteCasamento({ eventoInicial }: { eventoInicial: EventInfo }) {
  const [guest, setGuest] = useState(false);
  const [code, setCode] = useState("");
  const [view, setView] = useState<View>("inicio");
  const [confirmed, setConfirmed] = useState(false);
  const [notice, setNotice] = useState("");
  const [invitation, setInvitation] = useState<Invitation | null>(null);
  const [responses, setResponses] = useState<Record<string, "sim" | "nao">>({});
  const [idades, setIdades] = useState<Record<string, string>>({});
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [presentes, setPresentes] = useState<Presente[]>([]);
  const [carrinho, setCarrinho] = useState<Record<string, number>>({});
  const [presentesConfirmados, setPresentesConfirmados] = useState(false);
  const [mercadoPagoDisponivel, setMercadoPagoDisponivel] = useState(false),
    [historicoPresentes, setHistoricoPresentes] = useState<PresenteHistorico[]>(
      [],
    );
  const [senha, setSenha] = useState("");
  const [confirmarSenha, setConfirmarSenha] = useState("");
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [nomeCrianca, setNomeCrianca] = useState(""),
    [idadeCrianca, setIdadeCrianca] = useState("");
  const eventoPublico = eventoInicial;
  const [grupoSomenteLeitura, setGrupoSomenteLeitura] = useState(false),
    [codigoGestor, setCodigoGestor] = useState("");
  const [qrConvite, setQrConvite] = useState("");
  const [retornoPagamento, setRetornoPagamento] =
    useState<RetornoPagamento | null>(null);
  const [avisoPresencaAberto, setAvisoPresencaAberto] = useState(false);

  const carregarHistoricoPorCodigo = useCallback(async (codigoAcesso: string) => {
    const response = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "historico", codigo: codigoAcesso }),
    });
    const data = await response.json();
    if (response.ok) setHistoricoPresentes(data.historico ?? []);
  }, []);

  const acessarCodigo = useCallback(
    async (codigoAcesso: string, somenteGrupo = false) => {
      setLoading(true);
      setNotice("");
      try {
        const response = await fetch("/api/convite", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "buscar", codigo: codigoAcesso }),
        });
        const data = await response.json();
        if (!response.ok)
          throw new Error(data.error || "Não foi possível acessar o convite.");
        const redirecionarCodigo = String(
          data.redirecionar_codigo_individual ?? "",
        )
          .trim()
          .toUpperCase();
        const conviteIndividual = data.convite_individual === true;
        if (
          conviteIndividual &&
          /^[A-Z0-9]{6}$/.test(redirecionarCodigo) &&
          window.location.pathname.toUpperCase() !==
            `/C/${redirecionarCodigo}`
        ) {
          window.location.replace(
            `/c/${redirecionarCodigo}${window.location.search}`,
          );
          return;
        }
        const found = data.convite as Invitation;
        if (found.perfil_acesso === "admin")
          throw new Error("Use a área administrativa em /x.");
        const acessoPeloGrupo =
          !conviteIndividual &&
          found.codigo.toUpperCase() === found.codigo_conjunto.toUpperCase();
        const codigoIndividualUnico =
          found.convidados.length === 1
            ? found.convidados[0]?.codigo_individual?.trim().toUpperCase()
            : "";
        if (
          (somenteGrupo || acessoPeloGrupo) &&
          /^[A-Z0-9]{6}$/.test(codigoIndividualUnico) &&
          codigoIndividualUnico !== codigoAcesso.toUpperCase()
        ) {
          window.location.replace(
            `/c/${codigoIndividualUnico}${window.location.search}`,
          );
          return;
        }
        setInvitation(found);
        setPresentes(data.presentes ?? []);
        setMercadoPagoDisponivel(Boolean(data.mercado_pago_disponivel));
        setResponses(
          Object.fromEntries(
            found.convidados.map((person) => [
              person.id,
              person.status ?? "sim",
            ]),
          ),
        );
        setIdades(
          Object.fromEntries(
            found.convidados.map((person) => [
              person.id,
              person.idade === null ? "" : String(person.idade),
            ]),
          ),
        );
        setGuest(true);
        try {
          window.sessionStorage.setItem(
            "casamento_codigo_ativo",
            codigoAcesso.toUpperCase(),
          );
        } catch {
          // O código continua protegido na própria rota quando o armazenamento
          // do navegador estiver desativado.
        }
        if (found.perfil_acesso === "convidado")
          void carregarHistoricoPorCodigo(codigoAcesso);
        const somenteLeitura = somenteGrupo || acessoPeloGrupo;
        setGrupoSomenteLeitura(somenteLeitura);
        const rotaConvite = `/${somenteLeitura ? "g" : "c"}/${codigoAcesso.toUpperCase()}`;
        if (window.location.pathname !== rotaConvite)
          window.history.replaceState(
            {},
            "",
            `${rotaConvite}${window.location.search}`,
          );
        setQrConvite(
          await QRCode.toDataURL(
            `${window.location.origin}/${somenteLeitura ? "g" : "c"}/${codigoAcesso}`,
            {
              width: 280,
              margin: 1,
              color: { dark: "#53604f", light: "#fffdf9" },
            },
          ),
        );
        const organizacao =
          found.perfil_acesso === "noivos" ||
          found.perfil_acesso === "assessoria";
        const temPresencaConfirmada = found.convidados.some(
          (person) => person.status === "sim",
        );
        const retorno = retornoPagamentoAtual();
        setRetornoPagamento(retorno);
        if (retorno && !organizacao) {
          setView("presentes");
          setPresentesConfirmados(retorno.status === "sucesso");
          window.history.replaceState({}, "", rotaConvite);
          window.setTimeout(
            () => void carregarHistoricoPorCodigo(codigoAcesso),
            2500,
          );
        } else {
          setView(
            organizacao
              ? "noivos"
              : temPresencaConfirmada
                ? "inicio"
                : "convite",
          );
        }
      } catch (error) {
        setNotice(
          error instanceof Error
            ? error.message
            : "Não foi possível acessar o convite.",
        );
      } finally {
        setLoading(false);
      }
    },
    [carregarHistoricoPorCodigo],
  );

  useEffect(() => {
    const match = window.location.pathname.match(
      /^\/(c|g)\/([A-Za-z0-9]{6})\/?$/,
    );
    if (!match) return;
    const codigoRota = match[2].toUpperCase();
    queueMicrotask(() => {
      setCode(codigoRota);
      void acessarCodigo(codigoRota, match[1] === "g");
    });
  }, [acessarCodigo]);
  async function enter(event: FormEvent) {
    event.preventDefault();
    await acessarCodigo(code, false);
  }

  function abrirGerenciamentoPresenca() {
    if (!invitation) return;
    const chave = `casamento_aviso_presenca_${invitation.codigo.toUpperCase()}`;
    try {
      if (window.sessionStorage.getItem(chave) === "lido") {
        setView("presenca");
        return;
      }
    } catch {
      // O aviso continua funcional quando o armazenamento estiver desativado.
    }
    setAvisoPresencaAberto(true);
  }

  function confirmarLeituraAvisoPresenca() {
    if (invitation) {
      try {
        window.sessionStorage.setItem(
          `casamento_aviso_presenca_${invitation.codigo.toUpperCase()}`,
          "lido",
        );
      } catch {
        // A confirmação ainda vale para esta abertura.
      }
    }
    setAvisoPresencaAberto(false);
    setView("presenca");
  }
  async function liberarGrupo(event: FormEvent) {
    event.preventDefault();
    if (!invitation) return;
    setLoading(true);
    setNotice("");
    try {
      const response = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "buscar", codigo: codigoGestor }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "Código não encontrado.");
      const found = data.convite as Invitation;
      if (found.codigo_conjunto !== invitation.codigo_conjunto)
        throw new Error("Este código não pertence ao grupo.");
      if (!found.pode_gerenciar)
        throw new Error(
          "Esta pessoa não possui permissão para gerenciar o convite.",
        );
      setInvitation(found);
      setPresentes(data.presentes ?? []);
      setResponses(
        Object.fromEntries(
          found.convidados.map((person) => [person.id, person.status ?? "sim"]),
        ),
      );
      setIdades(
        Object.fromEntries(
          found.convidados.map((person) => [
            person.id,
            person.idade === null ? "" : String(person.idade),
          ]),
        ),
      );
      setGrupoSomenteLeitura(false);
      setCodigoGestor("");
    } catch (error) {
      setNotice(
        error instanceof Error
          ? error.message
          : "Não foi possível liberar o convite.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function carregarHistorico(codigoAcesso = invitation?.codigo) {
    if (!codigoAcesso) return;
    await carregarHistoricoPorCodigo(codigoAcesso);
  }
  async function confirmarPresentes(
    forma: "fisico" | "mercado_pago",
    dados?: { cpf?: string; aceite_privacidade?: boolean; mensagem?: string },
  ) {
    if (!invitation) return;
    setLoading(true);
    setNotice("");
    try {
      const itens = Object.entries(carrinho)
        .filter(([, q]) => q > 0)
        .map(([presente_id, quantidade]) => ({ presente_id, quantidade }));
      const response = await fetch("/api/mercado-pago", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: forma === "fisico" ? "fisico" : "criar_preferencia",
          codigo: invitation.codigo,
          itens,
          ...dados,
        }),
      });
      const data = await response.json();
      if (response.status === 428 && data.requer_cpf) return data;
      if (!response.ok)
        throw new Error(
          data.error || "Não foi possível confirmar os presentes.",
        );
      if (data.checkout_url) {
        try {
          window.sessionStorage.setItem(
            "casamento_codigo_ativo",
            invitation.codigo.toUpperCase(),
          );
        } catch {
          // A URL de retorno também contém o código do convite.
        }
        window.location.assign(data.checkout_url);
        return data;
      }
      setCarrinho({});
      setPresentesConfirmados(true);
      await carregarHistorico();
      return data;
    } catch (error) {
      setNotice(
        error instanceof Error
          ? error.message
          : "Não foi possível confirmar os presentes.",
      );
      return undefined;
    } finally {
      setLoading(false);
    }
  }
  async function alterarPresenteFisico(
    item: PresenteHistorico,
    quantidade: number,
  ) {
    if (!invitation || !Number.isInteger(quantidade) || quantidade < 1) return;
    const r = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "alterar_fisico",
        codigo: invitation.codigo,
        reserva_id: item.id,
        quantidade,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setNotice(d.error);
      return;
    }
    await carregarHistorico();
  }
  async function cancelarPresenteFisico(item: PresenteHistorico) {
    if (!invitation) return;
    const r = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "cancelar_fisico",
        codigo: invitation.codigo,
        reserva_id: item.id,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setNotice(d.error);
      return;
    }
    await carregarHistorico();
  }

  async function acessarNoivos(event: FormEvent) {
    event.preventDefault();
    if (!invitation) return;
    if (!invitation.senha_criada && senha !== confirmarSenha) {
      setNotice("As senhas digitadas não são iguais.");
      return;
    }
    setLoading(true);
    setNotice("");
    try {
      if (!invitation.senha_criada) {
        const r = await fetch("/api/convite", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action: "criar_senha_conta",
            codigo: invitation.codigo,
            senha,
          }),
        });
        const d = await r.json();
        if (!r.ok) throw new Error(d.error);
        setInvitation({ ...invitation, senha_criada: true });
      }
      const r = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "login_conta",
          codigo: invitation.codigo,
          senha,
        }),
      });
      const d = await r.json();
      if (!r.ok) throw new Error(d.error);
      const rd = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "dashboard",
          codigo: invitation.codigo,
        }),
      });
      const dd = await rd.json();
      if (!rd.ok) throw new Error(dd.error);
      setDashboard(dd.dashboard);
      setSenha("");
      setConfirmarSenha("");
    } catch (error) {
      setNotice(
        error instanceof Error ? error.message : "Não foi possível acessar.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function confirm(event: FormEvent) {
    event.preventDefault();
    if (!invitation || !invitation.pode_gerenciar || grupoSomenteLeitura) {
      setNotice("Somente uma pessoa autorizada do grupo pode salvar a confirmação.");
      return;
    }
    setLoading(true);
    setNotice("");
    try {
      const response = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "confirmar",
          codigo: invitation.codigo,
          respostas: invitation.convidados.map((person) => ({
            convidado_id: person.id,
            status: responses[person.id] ?? "sim",
            idade:
              person.crianca && responses[person.id] !== "nao"
                ? Number(idades[person.id])
                : null,
          })),
          mensagem: message,
        }),
      });
      const data = await response.json();
      if (!response.ok)
        throw new Error(data.error || "Não foi possível salvar.");
      const atualizada = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "buscar", codigo: invitation.codigo }),
      });
      const nova = await atualizada.json();
      if (atualizada.ok) setInvitation(nova.convite);
      setConfirmed(true);
    } catch (error) {
      setNotice(
        error instanceof Error ? error.message : "Não foi possível salvar.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function adicionarCrianca() {
    if (!invitation || !invitation.pode_gerenciar || grupoSomenteLeitura) return;
    setLoading(true);
    setNotice("");
    try {
      const response = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "adicionar_crianca",
          codigo: invitation.codigo,
          nome: nomeCrianca,
          idade: Number(idadeCrianca),
          solicitante:
            invitation.convidados.find(
              (pessoa) =>
                pessoa.codigo_individual.toUpperCase() ===
                invitation.codigo.toUpperCase(),
            )?.nome ?? "Responsável autorizado",
        }),
      });
      const data = await response.json();
      if (!response.ok)
        throw new Error(data.error || "Não foi possível adicionar.");
      const atualizada = await fetch("/api/convite", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "buscar", codigo: invitation.codigo }),
      });
      const nova = await atualizada.json();
      if (atualizada.ok) setInvitation(nova.convite);
      setNomeCrianca("");
      setIdadeCrianca("");
      setNotice(
        data.crianca
          ? "Criança adicionada ao grupo."
          : "Pessoa adicionada ao grupo como convidado.",
      );
    } catch (error) {
      setNotice(
        error instanceof Error ? error.message : "Não foi possível adicionar.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function sair() {
    await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "logout_conta" }),
    }).catch(() => undefined);
    setGuest(false);
    setInvitation(null);
    setDashboard(null);
    setCode("");
    setSenha("");
    setConfirmarSenha("");
    setNotice("");
    setRetornoPagamento(null);
    setView("inicio");
    try {
      window.sessionStorage.removeItem("casamento_codigo_ativo");
    } catch {
      // Nada a limpar quando o armazenamento estiver indisponível.
    }
    window.history.replaceState({}, "", "/");
  }

  const eventoAtual = invitation?.evento ?? eventoPublico ?? EVENTO_PADRAO;
  const dataEvento = partesEvento(eventoAtual);
  const acessoFuncoes = invitation
    ? resolverAcessoFuncoes(
        invitation.codigo,
        invitation.convidados,
        invitation.pode_gerenciar,
      )
    : null;
  const resumoFuncao = acessoFuncoes
    ? rotuloResumoFuncao(acessoFuncoes)
    : "";
  const funcaoOrganizacaoNormalizada = String(
    invitation?.funcao_cortejo ?? "",
  )
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toLocaleLowerCase("pt-BR");
  const perfilPaisOrganizacao = [
    "pai do noivo",
    "mae do noivo",
    "pai da noiva",
    "mae da noiva",
  ].includes(funcaoOrganizacaoNormalizada);
  const rotuloAreaOrganizacao = perfilPaisOrganizacao
    ? "Área da Organização"
    : invitation?.perfil_acesso === "assessoria"
      ? "Área da Assessoria"
      : "Área dos Noivos";

  if (!guest) {
    return (
      <main>
        <header className="topbar">
          <a className="brand" href="#inicio" aria-label="Início">
            <span className="monogram">
              <img src="/monograma-ga.png" alt="" />
            </span>
            <span>Gabriel &amp; Alanna</span>
          </a>
          <nav aria-label="Navegação principal">
            <a href="#historia">Uma breve história</a>
            <a href="#detalhes">O grande dia</a>
            <a href="#acesso">Área do convidado</a>
          </nav>
        </header>

        <section className="hero" id="inicio">
          <div className="vine vine-left" aria-hidden="true">
            ♥
          </div>
          <div className="hero-card">
            <p className="eyebrow">O que Deus uniu</p>
            <div className="seal">
              <img
                src="/monograma-ga.png"
                alt="Monograma de Gabriel e Alanna"
              />
            </div>
            <h1>
              Gabriel <em>&amp;</em> Alanna
            </h1>
            <p className="verse">
              “Assim, eles já não são dois, mas sim uma só carne.”
              <small>Mateus 19:6</small>
            </p>
            <div className="date">
              <span>{dataEvento.dia}</span>
              <i>{dataEvento.mes}</i>
              <span>{dataEvento.ano}</span>
            </div>
            <p className="time">
              {dataEvento.diaSemana}, às {dataEvento.hora} · {eventoAtual.cidade}
            </p>
            <a className="primary" href="#acesso">
              Acessar meu convite
            </a>
          </div>
          <div className="vine vine-right" aria-hidden="true">
            ♥
          </div>
          <span className="scroll">
            Role para descobrir <b>↓</b>
          </span>
        </section>

        <section className="story" id="historia">
          <p className="eyebrow">Uma breve história</p>
          <h2>Um amor guiado pela providência</h2>
          <p>
            Nossa história foi escrita no tempo certo, amadureceu com fé e agora
            nos conduz ao início de uma nova família.
          </p>
          <div className="milestones">
            <article>
              <b>Um começo...</b>
              <span>O evento de crianças que virou o sonho de jovens.</span>
            </article>
            <article>
              <b>Até aqui...</b>
              <span>
                Superando desafios e construindo com amor e fé as bases para o
                começo de uma história.
              </span>
            </article>
            <article>
              <b>O grande dia</b>
              <span>{dataEvento.dataExtenso}</span>
            </article>
          </div>
        </section>

        <section className="details" id="detalhes">
          <div>
            <p className="eyebrow">Reserve a data</p>
            <h2>O grande dia está chegando</h2>
            <p>
              Preparamos cada detalhe com carinho para celebrar ao lado das
              pessoas que fazem parte da nossa história.
            </p>
          </div>
          <div className="detail-card">
            <span>{dataEvento.dia}</span>
            <div>
              <b>
                {dataEvento.mes.charAt(0).toLocaleUpperCase("pt-BR") +
                  dataEvento.mes.slice(1)} de {dataEvento.ano}
              </b>
              <small>
                Cerimônia às {dataEvento.hora} · {eventoAtual.cidade}
              </small>
            </div>
          </div>
        </section>

        <section className="access" id="acesso">
          <div className="access-copy">
            <p className="eyebrow">Área do convidado</p>
            <h2>Seu convite, feito especialmente para você</h2>
            <p>
              Digite seu código individual de 6 caracteres para confirmar
              presença e acessar informações personalizadas.
            </p>
          </div>
          <form className="access-form" onSubmit={enter}>
            <label htmlFor="guest-code">Código individual do convidado</label>
            <div>
              <input
                id="guest-code"
                value={code}
                onChange={(e) =>
                  setCode(
                    e.target.value
                      .toUpperCase()
                      .replace(/[^A-Z0-9]/g, "")
                      .slice(0, 6),
                  )
                }
                minLength={6}
                maxLength={6}
                placeholder="Digite seu código de convidado"
                autoComplete="off"
              />
              <button className="primary" type="submit" disabled={loading}>
                {loading ? "Consultando..." : "Entrar"}
              </button>
            </div>
            {notice && (
              <p className="error" role="alert">
                {notice}
              </p>
            )}
          </form>
        </section>

        <footer>
          <span className="monogram">
            <img src="/monograma-ga.png" alt="Monograma de Gabriel e Alanna" />
          </span>
          <p>Gabriel &amp; Alanna · {dataEvento.dataNumerica}</p>
        </footer>
      </main>
    );
  }

  return (
    <main className="guest-app">
      <header className="guest-header">
        <button
          className="brand button-brand"
          onClick={() => setView("inicio")}
        >
          <span className="monogram">
            <img src="/monograma-ga.png" alt="" />
          </span>
          <span>Gabriel &amp; Alanna</span>
        </button>
        <nav aria-label="Área do convidado">
          {(invitation?.perfil_acesso === "noivos" ||
          invitation?.perfil_acesso === "assessoria"
            ? []
            : grupoSomenteLeitura
              ? ["convite" as View]
              : ([
                  "convite",
                  ...(invitation?.pode_gerenciar ? ["presenca" as View] : []),
                  "presentes",
                  ...(conviteTemPapel(invitation) ? ["cortejo" as View] : []),
                ] as View[])
          ).map((item) => (
            <button
              key={item}
              className={view === item ? "active" : ""}
              onClick={() =>
                item === "presenca"
                  ? abrirGerenciamentoPresenca()
                  : setView(item)
              }
            >
              {item === "presenca"
                ? "Gerenciar presença"
                : item === "cortejo"
                  ? "Meu papel"
                  : item}
            </button>
          ))}
        </nav>
        {(invitation?.nivel_acesso ?? 0) >= 3 && (
          <button
            className="couple-area"
            onClick={() => {
              setNotice("");
              setView("noivos");
            }}
          >
            {rotuloAreaOrganizacao}
          </button>
        )}
        <button className="exit" onClick={() => void sair()}>
          Sair
        </button>
      </header>

      {avisoPresencaAberto && (
        <div className="gift-modal-backdrop" role="presentation">
          <section
            className="gift-modal attendance-notice"
            role="dialog"
            aria-modal="true"
            aria-labelledby="attendance-notice-title"
          >
            <span className="gift-modal-icon">♡</span>
            <h2 id="attendance-notice-title">
              Um pedido especial aos nossos convidados:
            </h2>
            <p>
              Como nosso casamento será <strong>na véspera das eleições</strong>,
              pedimos que confirme sua presença apenas se realmente puder
              comparecer.
            </p>
            <p>
              Sua confirmação nos ajudará muito na organização desse dia tão
              especial!
            </p>
            <button className="primary" onClick={confirmarLeituraAvisoPresenca}>
              Li e entendi
            </button>
          </section>
        </div>
      )}

      <section className="guest-shell">
        <aside>
          <p>Convite de</p>
          <h3>{invitation?.nome_familia}</h3>
          {resumoFuncao && <span className="role">{resumoFuncao}</span>}
          <div className="mini-date">
            <b>{dataEvento.dia}</b>
            <span>
              {dataEvento.mesCurto}
              <br />
              {dataEvento.ano}
            </span>
          </div>
        </aside>
        <div className="guest-content">
          {view === "inicio" && (
            <div className="welcome">
              <p className="eyebrow">Sua página</p>
              <h1>Informações do casamento</h1>
              <p>
                Sua presença está confirmada. Nesta página você pode {" "}
                {invitation?.pode_gerenciar && !grupoSomenteLeitura
                  ? "gerenciar o convite, "
                  : "consultar o convite, "}
                acessar a lista de presentes e rever as informações para o
                grande dia.
              </p>
              <div className="welcome-actions">
                {invitation?.pode_gerenciar && !grupoSomenteLeitura ? (
                  <button
                    className="primary"
                    onClick={abrirGerenciamentoPresenca}
                  >
                    Gerenciar presença
                  </button>
                ) : (
                  <button
                    className="primary"
                    onClick={() => setView("convite")}
                  >
                    Ver convite
                  </button>
                )}
                <button className="secondary" onClick={() => setView("presentes")}>
                  Lista de presentes
                </button>
                {conviteTemPapel(invitation) && (
                  <button className="secondary" onClick={() => setView("cortejo")}>
                    Meu papel
                  </button>
                )}
              </div>
              <section className="quick-event-info" aria-label="Data e local do casamento">
                <p className="eyebrow">Informação rápida</p>
                <h2>{dataEvento.dataExtenso}</h2>
                <p>
                  Cerimônia às <b>{dataEvento.hora}</b> · {eventoAtual.cidade}
                </p>
                {eventoAtual.local_liberado && (
                  <p>
                    <b>{eventoAtual.nome_espaco}</b>
                    <br />
                    {eventoAtual.endereco}
                    {eventoAtual.link_maps && (
                      <>
                        <br />
                        <a href={eventoAtual.link_maps} target="_blank" rel="noreferrer">
                          Abrir no Google Maps
                        </a>
                      </>
                    )}
                  </p>
                )}
              </section>
            </div>
          )}
          {view === "convite" && (
            <div className="invitation panel">
              <p className="eyebrow">O que Deus uniu</p>
              <div className="seal small">
                <img
                  src="/monograma-ga.png"
                  alt="Monograma de Gabriel e Alanna"
                />
              </div>
              <h1>Gabriel &amp; Alanna</h1>
              <p>Convidam para a celebração de seu casamento</p>
              <p className="invitation-group">
                Convite para <b>{invitation?.nome_familia}</b>
              </p>
              <div className="date">
                <span>{dataEvento.dia}</span>
                <i>{dataEvento.mes}</i>
                <span>{dataEvento.ano}</span>
              </div>
              <p className="invitation-when">
                <b>{dataEvento.hora}</b>
                <br />
                {invitation?.evento?.cidade || "Candeias-BA"}
              </p>
              <p className="invitation-address">
                {invitation?.evento?.local_liberado ? (
                  <>
                    <b>{invitation.evento.nome_espaco}</b>
                    <br />
                    {invitation.evento.endereco}
                    {invitation.evento.link_maps && (
                      <>
                        <br />
                        <a
                          href={invitation.evento.link_maps}
                          target="_blank"
                          rel="noreferrer"
                        >
                          Abrir no Google Maps
                        </a>
                      </>
                    )}
                  </>
                ) : (
                  "Endereço: Aguardando a liberação."
                )}
              </p>
              {qrConvite && (
                <div className="invitation-qr">
                  <img src={qrConvite} alt="QR Code deste convite" />
                  <small>Abra este convite pelo QR Code</small>
                </div>
              )}
              {grupoSomenteLeitura && (
                <form className="group-manager-access" onSubmit={liberarGrupo}>
                  <h2>Gerenciar este convite</h2>
                  <p>
                    Informe o código individual de alguém autorizado no grupo
                    para confirmar a presença dos convidados.
                  </p>
                  <input
                    value={codigoGestor}
                    onChange={(e) =>
                      setCodigoGestor(
                        e.target.value
                          .toUpperCase()
                          .replace(/[^A-Z0-9]/g, "")
                          .slice(0, 6),
                      )
                    }
                    placeholder="Código individual"
                    minLength={6}
                    maxLength={6}
                    required
                  />
                  <button className="primary" disabled={loading}>
                    {loading ? "Verificando..." : "Continuar"}
                  </button>
                  {notice && <p className="error">{notice}</p>}
                </form>
              )}
              {invitation?.expirado ? (
                <div className="management-note expired-note">
                  <b>Convite com prazo de confirmação de 7 dias expirado.</b>
                  <p>
                    Caso tenha mudado de ideia ou tenha se passado do limite,
                    contate a organização ou os noivos para verificar a
                    possibilidade de reativar o convite.
                  </p>
                </div>
              ) : (
                <>
                  {!invitation?.prazo_vencido &&
                    !invitation?.sem_expiracao &&
                    invitation?.expira_em && (
                      <p className="deadline">
                        Confirme até{" "}
                        <b>
                          {new Date(invitation.expira_em).toLocaleString(
                            "pt-BR",
                          )}
                        </b>
                        .
                      </p>
                    )}
                  {invitation?.prazo_vencido && invitation.pode_gerenciar && (
                    <p className="deadline">
                      Sua presença está confirmada. Mesmo com o prazo encerrado,
                      você ainda pode alterar a resposta. Ao retirar a
                      confirmação, o convite ficará expirado em definitivo.
                    </p>
                  )}
                  {invitation?.pode_gerenciar && !grupoSomenteLeitura ? (
                    <button
                      className="primary"
                      onClick={abrirGerenciamentoPresenca}
                    >
                      Gerenciar presença
                    </button>
                  ) : !grupoSomenteLeitura ? (
                    <div className="management-note">
                      <b>Confirmação gerenciada por uma pessoa autorizada</b>
                      <p>
                        Para alterar a presença, fale com os noivos, a organização
                        ou um dos responsáveis listados para este grupo.
                      </p>
                    </div>
                  ) : null}
                </>
              )}
            </div>
          )}
          {view === "presenca" && (
            <div className="panel rsvp">
              {!confirmed ? (
                <>
                  <p className="eyebrow">Confirmação de presença</p>
                  <h1>Esperamos por vocês</h1>
                  <p>
                    {invitation?.pode_gerenciar
                      ? "Você pode responder por todas as pessoas deste conjunto."
                      : "Confirme abaixo a sua própria presença."}
                  </p>
                  {!invitation?.pode_gerenciar && (
                    <div className="management-note">
                      <b>
                        Contate os noivos, a organização ou o responsável pelo
                        seu convite.
                      </b>
                      <p>Pessoas que podem gerenciar este conjunto:</p>
                      <ul>
                        {invitation?.responsaveis.length ? (
                          invitation.responsaveis.map((p) => (
                            <li key={p.id}>
                              {p.nome}
                              {p.funcao ? ` · ${p.funcao}` : ""}
                            </li>
                          ))
                        ) : (
                          <li>
                            Nenhum responsável definido. Contate os noivos ou a
                            organização.
                          </li>
                        )}
                      </ul>
                    </div>
                  )}
                  {!invitation?.pode_gerenciar || grupoSomenteLeitura ? (
                    <div className="management-note">
                      <b>Este acesso é somente para consulta.</b>
                      <p>
                        Use o código individual de uma pessoa autorizada do grupo
                        para confirmar ou alterar presenças.
                      </p>
                    </div>
                  ) : invitation?.expirado ? (
                    <div className="management-note expired-note">
                      <b>
                        Convite com prazo de confirmação de 7 dias expirado.
                      </b>
                      <p>
                        Contate a organização ou os noivos para verificar a
                        possibilidade de reativar o convite.
                      </p>
                    </div>
                  ) : (
                    <form onSubmit={confirm}>
                      {invitation?.prazo_vencido && (
                        <div className="management-note">
                          <b>Alteração após o prazo</b>
                          <p>
                            Você pode retirar a confirmação. Depois de salvar
                            sem nenhuma presença confirmada, este convite ficará
                            expirado em definitivo.
                          </p>
                        </div>
                      )}
                      {invitation?.convidados.map((person) => (
                        <div className="person-row" key={person.id}>
                          <div>
                            <b>{person.nome}</b>
                            <small>
                              {person.crianca
                                ? `Criança${person.idade !== null ? ` · ${person.idade} anos` : " · informe a idade ao confirmar"}`
                                : person.funcao || "Convidado"}{" "}
                              · código {person.codigo_individual}
                            </small>
                          </div>
                          <div
                            className="attendance-choice"
                            role="group"
                            aria-label={`Presença de ${person.nome}`}
                          >
                            <button
                              type="button"
                              className={responses[person.id] === "sim" ? "selected" : ""}
                              aria-pressed={responses[person.id] === "sim"}
                              onClick={() =>
                                setResponses((current) => ({
                                  ...current,
                                  [person.id]: "sim",
                                }))
                              }
                            >
                              Estarei presente
                            </button>
                            <button
                              type="button"
                              className={responses[person.id] === "nao" ? "selected decline" : ""}
                              aria-pressed={responses[person.id] === "nao"}
                              onClick={() =>
                                setResponses((current) => ({
                                  ...current,
                                  [person.id]: "nao",
                                }))
                              }
                            >
                              Não poderei ir
                            </button>
                          </div>
                          {person.crianca && responses[person.id] !== "nao" && (
                            <input
                              aria-label={`Idade de ${person.nome}`}
                              type="number"
                              min={0}
                              max={17}
                              placeholder="Idade"
                              value={idades[person.id] ?? ""}
                              onChange={(e) =>
                                setIdades((a) => ({
                                  ...a,
                                  [person.id]: e.target.value,
                                }))
                              }
                              required
                            />
                          )}
                        </div>
                      ))}
                      {invitation?.pode_gerenciar &&
                        (invitation?.criancas_adicionais_restantes ?? 0) > 0 && (
                        <section className="management-note">
                          <b>Adicionar criança ao grupo</b>
                          <p>
                            Este grupo ainda pode adicionar{" "}
                            {invitation?.criancas_adicionais_restantes}{" "}
                            pessoa(s) menor(es) de 18 anos.
                          </p>
                          <div className="admin-form">
                            <input
                              placeholder="Nome completo"
                              value={nomeCrianca}
                              onChange={(e) => setNomeCrianca(e.target.value)}
                              required
                            />
                            <input
                              type="number"
                              min={0}
                              max={120}
                              placeholder="Idade"
                              value={idadeCrianca}
                              onChange={(e) => setIdadeCrianca(e.target.value)}
                              required
                            />
                            <button
                              type="button"
                              className="secondary"
                              disabled={
                                loading ||
                                !nomeCrianca.trim() ||
                                !idadeCrianca
                              }
                              onClick={adicionarCrianca}
                            >
                              Adicionar ao grupo
                            </button>
                          </div>
                          <small>
                            Menores ou iguais a{" "}
                            {invitation?.idade_limite_crianca ?? 8} anos são
                            classificados como criança. Pessoas de 18 anos ou
                            mais precisam ser solicitadas à organização.
                          </small>
                        </section>
                      )}
                      <label htmlFor="message">
                        Mensagem para os noivos (opcional)
                      </label>
                      <textarea
                        id="message"
                        value={message}
                        onChange={(event) => setMessage(event.target.value)}
                        placeholder="Escreva uma mensagem carinhosa..."
                      />
                      {notice && (
                        <p className="error" role="alert">
                          {notice}
                        </p>
                      )}
                      <button
                        className="primary"
                        type="submit"
                        disabled={loading}
                      >
                        {loading ? "Salvando..." : "Salvar confirmação"}
                      </button>
                    </form>
                  )}
                </>
              ) : (
                <div className="success">
                  <span>✓</span>
                  <p className="eyebrow">Resposta registrada</p>
                  <h1>Obrigado por atualizar o convite!</h1>
                  <p>
                    Sua resposta foi salva no banco de dados. Você pode
                    alterá-la até o prazo informado pelos noivos.
                  </p>
                  <button
                    className="secondary"
                    onClick={() => setConfirmed(false)}
                  >
                    Alterar resposta
                  </button>
                </div>
              )}
            </div>
          )}
          {view === "presentes" && (
            <>
              {retornoPagamento && (
                <div
                  className={`payment-return-status ${retornoPagamento.status}`}
                  role="status"
                >
                  <b>
                    {retornoPagamento.status === "sucesso"
                      ? "Retorno do pagamento"
                      : retornoPagamento.status === "pendente"
                        ? "Pagamento em processamento"
                        : "Pagamento não concluído"}
                  </b>
                  <span>{retornoPagamento.mensagem}</span>
                </div>
              )}
              <ListaPresentes
                presentes={presentes}
                carrinho={carrinho}
                carregando={loading}
                confirmado={presentesConfirmados}
                mercadoPagoDisponivel={mercadoPagoDisponivel}
                historico={historicoPresentes}
                aoAlterar={(id, q) => {
                  setPresentesConfirmados(false);
                  setCarrinho((a) => ({ ...a, [id]: q }));
                }}
                aoEscolherForma={confirmarPresentes}
                aoAlterarFisico={alterarPresenteFisico}
                aoCancelarFisico={cancelarPresenteFisico}
              />
              {notice && (
                <p className="error floating-error" role="alert">
                  {notice}
                </p>
              )}
            </>
          )}
          {view === "cortejo" && acessoFuncoes?.temFuncao && (
            <ManualFuncao acesso={acessoFuncoes} />
          )}
          {view === "noivos" &&
            (dashboard ? (
              <DashboardNoivos
                dados={dashboard}
                codigo={invitation?.codigo ?? ""}
              />
            ) : (
              <div className="panel couple-login">
                <p className="eyebrow">Área reservada</p>
                <h1>
                  {invitation?.senha_criada
                    ? `Entrar na ${rotuloAreaOrganizacao}`
                    : `Crie a senha ${perfilPaisOrganizacao ? "da organização" : invitation?.perfil_acesso === "assessoria" ? "da assessoria" : "dos noivos"}`}
                </h1>
                <p>
                  {invitation?.senha_criada
                    ? invitation.exige_troca_senha
                      ? "Use a senha temporária informada pelo administrador. Depois do acesso, você deverá criar uma nova senha."
                      : "Use a senha criada no primeiro acesso."
                    : "Este é o primeiro acesso. Crie uma senha com pelo menos 8 caracteres."}
                </p>
                <form onSubmit={acessarNoivos}>
                  <label htmlFor="couple-password">Senha</label>
                  <input
                    id="couple-password"
                    type="password"
                    minLength={
                      invitation?.senha_criada && invitation.exige_troca_senha
                        ? 6
                        : 8
                    }
                    maxLength={128}
                    value={senha}
                    onChange={(e) => setSenha(e.target.value)}
                    required
                    autoComplete={
                      invitation?.senha_criada
                        ? "current-password"
                        : "new-password"
                    }
                  />
                  {!invitation?.senha_criada && (
                    <>
                      <label htmlFor="confirm-password">Confirmar senha</label>
                      <input
                        id="confirm-password"
                        type="password"
                        minLength={8}
                        maxLength={128}
                        value={confirmarSenha}
                        onChange={(e) => setConfirmarSenha(e.target.value)}
                        required
                        autoComplete="new-password"
                      />
                    </>
                  )}
                  {notice && (
                    <p className="error" role="alert">
                      {notice}
                    </p>
                  )}
                  <button className="primary" disabled={loading}>
                    {loading
                      ? "Acessando..."
                      : invitation?.senha_criada
                        ? "Entrar"
                        : "Criar senha e entrar"}
                  </button>
                </form>
              </div>
            ))}
        </div>
      </section>
    </main>
  );
}
