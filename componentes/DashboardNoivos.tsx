"use client";
import { FormEvent, useMemo, useState } from "react";
import { ExportarConvites } from "./ExportarConvites";
import { ControlesAdministrativos } from "./ControlesAdministrativos";
import * as XLSX from "xlsx";

type OrigemConvidado = "noivo" | "noiva" | "ambos" | "nao_classificado";
type Pessoa = {
  id: string;
  convite_id: string;
  nome: string;
  principal: boolean;
  pode_gerenciar: boolean;
  status: "confirmado" | "aguardando" | "expirado";
  resposta: "sim" | "nao" | null;
  crianca: boolean;
  idade: number | null;
  codigo: string;
  codigo_individual: string;
  conjunto: string;
  funcao: string | null;
  origem: OrigemConvidado;
  nivel_acesso: number;
  protegido: boolean;
  expira_em: string | null;
  sem_expiracao: boolean;
  expirado: boolean;
  visualizado_em: string | null;
};
type LinhaImportacao = {
  nome: string;
  grupo: string;
  funcao: string;
  origem: OrigemConvidado;
};
type LinhaPresenteImportacao = {
  nome: string;
  categoria: string;
  valor: number;
  links_fotos: string[];
  descricao: string;
  quantidade: number;
};
type DuplicidadeImportacao = {
  linha: LinhaImportacao;
  encontrados: string[];
  criar: boolean;
};
type Reserva = {
  id: string;
  convidado: string;
  codigo: string;
  presente: string;
  quantidade: number;
  criado_em: string;
};
type Grupo = {
  id: string;
  codigo: string;
  titulo: string;
  total: number;
  protegido: boolean;
  criancas_adicionais_limite: number;
  criancas_adicionais_usadas: number;
};
type Mensagem = {
  grupo: string;
  codigo: string;
  mensagem: string;
  atualizado_em: string;
};
type Notificacao = {
  grupo: string;
  codigo: string;
  mensagem: string;
  criado_em: string;
};
type Organizacao = {
  id: string;
  nome: string;
  usuario: string;
  codigo: string | null;
  funcao: "administrador" | "noivo" | "noiva" | "assessoria";
  administrador: boolean;
  principal: boolean;
  senha_criada: boolean;
  exige_troca_senha: boolean;
};
type PresenteAdmin = {
  id: string;
  nome: string;
  descricao: string | null;
  imagens: string[];
  categoria_id: string | null;
  categoria: string | null;
  preco_centavos: number;
  quantidade_total: number;
  quantidade_assinada: number;
  quantidade_restante: number;
};
type Evento = {
  data: string;
  hora: string;
  cidade: string;
  local_liberado: boolean;
  nome_espaco: string;
  endereco: string;
  link_maps: string | null;
};
type Categoria = { id: string; nome: string; ordem: number; ativo: boolean };
type Configuracoes = {
  url_base: string;
  mensagem_confirmacao: string;
  titulo_site: string;
  dias_expiracao_padrao: number;
};
type PagamentoAdmin = {
  id: string;
  pagamento_id: string | null;
  external_reference: string | null;
  status: "pendente" | "confirmado" | "rejeitado" | "reembolsado";
  pagamento_status: string | null;
  pagador_nome: string;
  pagador_email: string | null;
  meio_pagamento: string;
  valor: number | null;
  criado_em: string;
  aprovado_em: string | null;
  reembolso_id: string | null;
  reembolsado_em: string | null;
  convite_codigo: string | null;
  itens: Array<{ nome: string; quantidade: number }>;
};
const FUNCOES = [
  "Convidado",
  "Padrinho",
  "Madrinha",
  "Demoiselle",
  "Amigo do Noivo",
  "Pajem",
  "Daminha",
  "Florista",
  "Porta-bíblia",
  "Porta-alianças",
  "Pai do Noivo",
  "Mãe do Noivo",
  "Pai da Noiva",
  "Mãe da Noiva",
];
export type Dashboard = {
  perfil: "noivos" | "assessoria" | "admin";
  conta: {
    id: string;
    nome: string;
    usuario: string;
    funcao: string;
    principal: boolean;
    exige_troca_senha: boolean;
  };
  evento: Evento;
  configuracoes?: Configuracoes;
  categorias_presentes?: Categoria[];
  idade_limite_crianca: number;
  convidados_total: number;
  confirmados: number;
  nao_comparecem: number;
  aguardando: number;
  presentes_assinados: number;
  convidados: Pessoa[];
  organizacao?: Organizacao[];
  grupos?: Grupo[];
  mensagens?: Mensagem[];
  notificacoes?: Notificacao[];
  reservas: Reserva[];
  ultimas_confirmacoes: Array<{
    nome: string;
    status: "sim" | "nao";
    mensagem: string | null;
    atualizado_em: string;
  }>;
};

function baixarCsv(
  nome: string,
  cabecalho: string[],
  linhas: (string | number | boolean | null | undefined)[][],
) {
  const esc = (v: unknown) => `"${String(v ?? "").replaceAll('"', '""')}"`;
  const csv =
    "\ufeff" +
    [cabecalho, ...linhas].map((l) => l.map(esc).join(";")).join("\r\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(
    new Blob([csv], { type: "text/csv;charset=utf-8" }),
  );
  a.download = nome;
  a.click();
  URL.revokeObjectURL(a.href);
}
const normalizar = (valor: string) =>
  valor
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();

export function DashboardNoivos({
  dados: inicial,
  codigo,
}: {
  dados: Dashboard;
  codigo: string;
}) {
  const [dados, setDados] = useState(inicial),
    [pagina, setPagina] = useState<
      | "geral"
      | "convidados"
      | "grupos"
      | "mensagens"
      | "notificacoes"
      | "presentes"
      | "organizacao"
      | "evento"
      | "senha"
      | "configuracoes"
      | "configuracoes_presentes"
      | "pagamentos"
      | "exportar"
      | "controles"
    >(inicial.conta?.exige_troca_senha ? "senha" : "geral");
  const [filtro, setFiltro] = useState<
      "todos" | "sim" | "nao" | "aguardando" | "presentes"
    >("todos"),
    [editando, setEditando] = useState<Pessoa | null>(null);
  const [nome, setNome] = useState(""),
    [codigoIndividual, setCodigoIndividual] = useState(""),
    [grupo, setGrupo] = useState(""),
    [funcao, setFuncao] = useState(""),
    [origem, setOrigem] = useState<OrigemConvidado>("nao_classificado"),
    [principal, setPrincipal] = useState(false),
    [gestor, setGestor] = useState(false),
    [crianca, setCrianca] = useState(false),
    [aviso, setAviso] = useState("");
  const [duplicidades, setDuplicidades] = useState<DuplicidadeImportacao[]>([]),
    [importadosAntesDuplicidades, setImportadosAntesDuplicidades] = useState(0),
    [importando, setImportando] = useState(false);
  const [pesquisa, setPesquisa] = useState("");
  const [grupoEditando, setGrupoEditando] = useState<Grupo | null>(null),
    [codigoGrupo, setCodigoGrupo] = useState(""),
    [tituloGrupo, setTituloGrupo] = useState(""),
    [criancasExtras, setCriancasExtras] = useState(0),
    [idadeLimite, setIdadeLimite] = useState(inicial.idade_limite_crianca ?? 8);
  const [orgEditando, setOrgEditando] = useState<Organizacao | null>(null),
    [orgNome, setOrgNome] = useState(""),
    [orgUsuario, setOrgUsuario] = useState(""),
    [orgCodigo, setOrgCodigo] = useState(""),
    [orgFuncao, setOrgFuncao] = useState<Organizacao["funcao"]>("assessoria"),
    [orgAdmin, setOrgAdmin] = useState(false),
    [credenciaisGeradas, setCredenciaisGeradas] = useState<{
      codigo?: string;
      senhaTemporaria?: string;
    } | null>(null);
  const [senhaAtual, setSenhaAtual] = useState(""),
    [novaSenha, setNovaSenha] = useState(""),
    [confirmaNovaSenha, setConfirmaNovaSenha] = useState("");
  const [presentes, setPresentes] = useState<PresenteAdmin[]>([]),
    [presenteEditando, setPresenteEditando] = useState<string | null>(null),
    [urlsImagens, setUrlsImagens] = useState(""),
    [carregandoPresentes, setCarregandoPresentes] = useState(false);
  const [categorias, setCategorias] = useState<Categoria[]>(
      inicial.categorias_presentes ?? [],
    ),
    [novaCategoria, setNovaCategoria] = useState("");
  const [configuracoes, setConfiguracoes] = useState<Configuracoes>(
    inicial.configuracoes ?? {
      url_base: "https://gabriel-alanna-casamento.rexmeil.chatgpt.site",
      mensagem_confirmacao:
        "Acesse pelo QR Code, informe seu código e confirme a presença.",
      titulo_site: "O Que Deus Uniu",
      dias_expiracao_padrao: 7,
    },
  );
  const [mp, setMp] = useState<{
      ativa: boolean;
      public_key: string;
      access_token_mascarado: string;
      conta_id: string | null;
      conta_email: string | null;
      ambiente: string;
      verificada_em: string | null;
      recolher_cpf: boolean;
      cpf_valor_minimo_centavos: number;
    } | null>(null),
    [pagamentos, setPagamentos] = useState<PagamentoAdmin[]>([]),
    [mpPublicKey, setMpPublicKey] = useState(""),
    [mpToken, setMpToken] = useState(""),
    [mpAmbiente, setMpAmbiente] = useState<"teste" | "producao">("producao"),
    [mpCarregando, setMpCarregando] = useState(false),
    [recolherCpf, setRecolherCpf] = useState(false),
    [cpfMinimo, setCpfMinimo] = useState(350);
  const [evento, setEvento] = useState<Evento>(
    inicial.evento ?? {
      data: "2026-10-03",
      hora: "18:30",
      cidade: "Candeias-BA",
      local_liberado: false,
      nome_espaco: "Espaço Brunus",
      endereco: "Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000",
      link_maps: null,
    },
  );
  const assessoria = dados.perfil === "assessoria";
  const admin = dados.perfil === "admin";
  const grupos = useMemo(
    () =>
      dados.grupos?.length
        ? dados.grupos
        : Array.from(
            new Map(
              dados.convidados.map((p) => [
                p.codigo,
                {
                  id: p.codigo,
                  codigo: p.codigo,
                  titulo: p.conjunto,
                  total: dados.convidados.filter((x) => x.codigo === p.codigo)
                    .length,
                  protegido: p.protegido,
                  criancas_adicionais_limite: 0,
                  criancas_adicionais_usadas: 0,
                },
              ]),
            ).values(),
          ),
    [dados],
  );
  const convidadosFiltrados = useMemo(() => {
    const termo = normalizar(pesquisa);
    if (!termo) return dados.convidados;
    return dados.convidados.filter((p) =>
      normalizar(
        [
          p.nome,
          p.codigo_individual,
          p.codigo,
          p.conjunto,
          p.funcao ?? "",
        ].join(" "),
      ).includes(termo),
    );
  }, [dados.convidados, pesquisa]);
  const lista =
    filtro === "sim"
      ? dados.convidados.filter((p) => p.resposta === "sim")
      : filtro === "nao"
        ? dados.convidados.filter((p) => p.resposta === "nao")
      : filtro === "aguardando"
        ? dados.convidados.filter((p) => p.status === "aguardando")
        : dados.convidados;

  async function recarregar() {
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "dashboard", codigo }),
    });
    const d = await r.json();
    if (r.ok) setDados(d.dashboard);
  }
  async function administrar(acao: string, dadosAcao: Record<string, unknown>) {
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar",
        codigo,
        acao,
        dados: dadosAcao,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar.");
      return false;
    }
    await recarregar();
    return true;
  }
  async function administrarGrupo(
    acao: string,
    dadosAcao: Record<string, unknown>,
  ) {
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_grupos",
        codigo,
        acao,
        dados: dadosAcao,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar o grupo.");
      return false;
    }
    await recarregar();
    return true;
  }
  async function administrarOrganizacao(
    acao: string,
    dadosAcao: Record<string, unknown>,
  ) {
    setAviso("");
    setCredenciaisGeradas(null);
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_organizacao",
        codigo,
        acao,
        dados: dadosAcao,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar.");
      return false;
    }
    if (d.codigo || d.senha_temporaria)
      setCredenciaisGeradas({
        codigo: d.codigo,
        senhaTemporaria: d.senha_temporaria,
      });
    await recarregar();
    return true;
  }
  async function alterarSenha(e: FormEvent) {
    e.preventDefault();
    setAviso("");
    if (novaSenha !== confirmaNovaSenha) {
      setAviso("As novas senhas não são iguais.");
      return;
    }
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "alterar_propria_senha",
        codigo,
        senha_atual: senhaAtual,
        nova_senha: novaSenha,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível alterar a senha.");
      return;
    }
    setSenhaAtual("");
    setNovaSenha("");
    setConfirmaNovaSenha("");
    setDados((atual) => ({
      ...atual,
      conta: { ...atual.conta, exige_troca_senha: false },
    }));
    setPagina("geral");
    setAviso("Senha alterada com sucesso.");
  }
  async function expirar(convite_id: string, acao: string, data?: string) {
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_expiracao",
        codigo,
        acao,
        dados: { convite_id, data: data || null },
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível alterar o prazo.");
      return;
    }
    await recarregar();
  }
  async function carregarPresentes() {
    setCarregandoPresentes(true);
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "listar_presentes_dashboard", codigo }),
    });
    const d = await r.json();
    setCarregandoPresentes(false);
    if (!r.ok) {
      setAviso(d.error || "Não foi possível carregar os presentes.");
      return [] as PresenteAdmin[];
    }
    const lista = (d.presentes ?? []) as PresenteAdmin[];
    setPresentes(lista);
    return lista;
  }
  async function salvarImagensPresente(presente_id: string) {
    const imagens = urlsImagens
      .split(/\r?\n/)
      .map((v) => v.trim())
      .filter(Boolean);
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_imagens_presente",
        codigo,
        dados: { presente_id, imagens },
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar as imagens.");
      return;
    }
    setPresenteEditando(null);
    setUrlsImagens("");
    await carregarPresentes();
    setAviso("Imagens do presente atualizadas com sucesso.");
  }
  async function acaoConfiguracao(
    acao: string,
    dadosAcao: Record<string, unknown>,
  ) {
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_configuracoes",
        codigo,
        acao,
        dados: dadosAcao,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar as configurações.");
      return false;
    }
    await recarregar();
    return true;
  }
  async function salvarConfiguracoes(e: FormEvent) {
    e.preventDefault();
    if (await acaoConfiguracao("gerais", configuracoes))
      setAviso("Configurações gerais atualizadas com sucesso.");
  }
  async function carregarMercadoPago() {
    setMpCarregando(true);
    setAviso("");
    const r = await fetch("/api/mercado-pago");
    const d = await r.json();
    setMpCarregando(false);
    if (!r.ok) {
      setAviso(d.error || "Não foi possível consultar a integração.");
      return;
    }
    setMp(d.configuracao);
    setPagamentos(d.pagamentos ?? []);
    setMpPublicKey(d.configuracao?.public_key ?? "");
    setMpAmbiente(d.configuracao?.ambiente === "teste" ? "teste" : "producao");
    setRecolherCpf(Boolean(d.configuracao?.recolher_cpf));
    setCpfMinimo(
      Number(d.configuracao?.cpf_valor_minimo_centavos ?? 35000) / 100,
    );
  }
  async function salvarMercadoPago(e: FormEvent) {
    e.preventDefault();
    setMpCarregando(true);
    setAviso("");
    const r = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "salvar_credenciais",
        public_key: mpPublicKey,
        access_token: mpToken,
        ambiente: mpAmbiente,
      }),
    });
    const d = await r.json();
    setMpCarregando(false);
    if (!r.ok) {
      setAviso(d.error || "Não foi possível validar as credenciais.");
      return;
    }
    setMpToken("");
    setAviso("Conexão com o Mercado Pago validada e ativada com sucesso.");
    await carregarMercadoPago();
  }
  async function desativarMercadoPago() {
    if (!confirm("Desativar os pagamentos pelo Mercado Pago?")) return;
    await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "desativar" }),
    });
    await carregarMercadoPago();
  }
  async function salvarConfiguracaoCpf(e: FormEvent) {
    e.preventDefault();
    setMpCarregando(true);
    setAviso("");
    const r = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "configurar_cpf",
        recolher_cpf: recolherCpf,
        cpf_valor_minimo_centavos: Math.round(cpfMinimo * 100),
      }),
    });
    const d = await r.json();
    setMpCarregando(false);
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar a configuração de CPF.");
      return;
    }
    setAviso("Configuração de CPF atualizada com sucesso.");
    await carregarMercadoPago();
  }
  async function reembolsarPagamento(p: PagamentoAdmin) {
    if (
      !p.pagamento_id ||
      !confirm(
        `Confirmar o reembolso integral de ${p.pagador_nome}? Esta ação não pode ser desfeita pelo site.`,
      )
    )
      return;
    setMpCarregando(true);
    setAviso("");
    const r = await fetch("/api/mercado-pago", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "reembolsar",
        pagamento_id: p.pagamento_id,
      }),
    });
    const d = await r.json();
    setMpCarregando(false);
    if (!r.ok) {
      setAviso(d.error || "Não foi possível realizar o reembolso.");
      return;
    }
    setAviso("Reembolso solicitado com sucesso ao Mercado Pago.");
    await carregarMercadoPago();
  }
  async function adicionarCategoria(e: FormEvent) {
    e.preventDefault();
    if (await acaoConfiguracao("criar_categoria", { nome: novaCategoria })) {
      setNovaCategoria("");
      setCategorias((await carregarDadosAuxiliares()).categorias);
    }
  }
  async function carregarDadosAuxiliares() {
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "configuracoes_dashboard", codigo }),
    });
    const d = await r.json();
    if (r.ok) {
      setCategorias(d.categorias ?? []);
      setConfiguracoes(d.configuracoes ?? configuracoes);
    }
    return { categorias: d.categorias ?? [] };
  }
  async function categoriaPresente(presente_id: string, categoria_id: string) {
    if (
      await acaoConfiguracao("categoria_presente", {
        presente_id,
        categoria_id: categoria_id || null,
      })
    ) {
      await carregarPresentes();
      setAviso("Categoria do presente atualizada com sucesso.");
    }
  }
  async function salvarGrupo(e: FormEvent) {
    e.preventDefault();
    const ok = await administrarGrupo(grupoEditando ? "editar" : "criar", {
      id: grupoEditando?.id,
      codigo: codigoGrupo.trim().toUpperCase(),
      titulo: tituloGrupo.trim(),
      criancas_adicionais_limite: criancasExtras,
    });
    if (ok) {
      setGrupoEditando(null);
      setCodigoGrupo("");
      setTituloGrupo("");
      setCriancasExtras(0);
    }
  }
  async function salvar(e: FormEvent) {
    e.preventDefault();
    const codigoDesejado = codigoIndividual.trim().toUpperCase();
    if (codigoDesejado && !/^[A-Z0-9]{6}$/.test(codigoDesejado)) {
      setAviso("O código deve ter exatamente 6 letras ou números.");
      return;
    }
    const ok = await administrar(
      assessoria ? "editar_restrito" : codigoDesejado ? (editando ? "editar_com_codigo" : "adicionar_com_codigo") : editando ? "editar" : "adicionar",
      {
        id: editando?.id,
        nome,
        codigo: editando ? grupo : undefined,
        funcao,
        origem,
        principal,
        pode_gerenciar: editando ? gestor : true,
        crianca,
        codigo_individual: codigoDesejado || undefined,
      },
    );
    if (ok) {
      setEditando(null);
      setNome("");
      setCodigoIndividual("");
      setGrupo("");
      setFuncao("");
      setOrigem("nao_classificado");
      setPrincipal(false);
      setGestor(false);
      setCrianca(false);
    }
  }
  function abrirEdicao(p: Pessoa) {
    setEditando(p);
    setNome(p.nome);
    setCodigoIndividual(p.codigo_individual);
    setGrupo(p.codigo);
    setFuncao(p.funcao ?? "");
    setOrigem(p.origem ?? "nao_classificado");
    setPrincipal(p.principal);
    setGestor(p.pode_gerenciar);
    setCrianca(p.crianca);
  }
  async function salvarIdadeLimite() {
    const ok = await administrar("configurar_idade_crianca", {
      idade: idadeLimite,
    });
    if (ok) setAviso("Limite de idade atualizado.");
  }
  async function salvarEvento(e: FormEvent) {
    e.preventDefault();
    setAviso("");
    const r = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "administrar_evento",
        codigo,
        dados: evento,
      }),
    });
    const d = await r.json();
    if (!r.ok) {
      setAviso(d.error || "Não foi possível salvar os dados do evento.");
      return;
    }
    await recarregar();
    setAviso("Dados do evento atualizados com sucesso.");
  }
  async function enviarImportacao(linhas: LinhaImportacao[]) {
    if (!linhas.length) return 0;
    const resposta = await fetch("/api/convite", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "importar_convidados", codigo, linhas }),
    });
    const resultado = await resposta.json();
    if (!resposta.ok)
      throw new Error(resultado.error || "Não foi possível importar.");
    return Number(resultado.importados) || 0;
  }
  async function importar(file: File) {
    setImportando(true);
    try {
      setAviso("");
      const workbook = XLSX.read(await file.arrayBuffer(), { type: "array" });
      const folha = workbook.Sheets[workbook.SheetNames[0]];
      const tabela = XLSX.utils.sheet_to_json<(string | number)[]>(folha, {
        header: 1,
        defval: "",
        raw: false,
      });
      if (tabela.length < 2) {
        setAviso(
          "A planilha precisa ter o cabeçalho nome e pelo menos um convidado.",
        );
        return;
      }
      const [cabBruto, ...rowsBrutas] = tabela;
      const cab = cabBruto.map((c) => String(c).trim());
      const rows = rowsBrutas.map((r) => r.map((c) => String(c).trim()));
      const idx = (n: string) =>
          cab.findIndex((c) => normalizar(c).replace(/\s+/g, "_") === n),
        nomeIdx = idx("nome"),
        grupoIdx = idx("grupo"),
        funcaoIdx = idx("funcao"),
        origemIdx = Math.max(idx("origem"), idx("convidado_de"));
      if (nomeIdx < 0) {
        setAviso('A planilha precisa ter uma coluna chamada "nome".');
        return;
      }
      const origemValida = (valor: string): OrigemConvidado => {
        const v = normalizar(valor).replace(/\s+/g, "_");
        return v === "noivo" || v === "noiva" || v === "ambos"
          ? v
          : "nao_classificado";
      };
      const linhas = rows
        .map((r) => ({
          nome: r[nomeIdx]?.trim() ?? "",
          grupo: grupoIdx >= 0 ? (r[grupoIdx]?.trim() ?? "") : "",
          funcao: funcaoIdx >= 0 ? (r[funcaoIdx]?.trim() ?? "") : "",
          origem:
            origemIdx >= 0
              ? origemValida(r[origemIdx] ?? "")
              : ("nao_classificado" as OrigemConvidado),
        }))
        .filter((x) => x.nome.length >= 2);
      if (!linhas.length) {
        setAviso("Nenhum nome válido foi encontrado na planilha.");
        return;
      }
      const existentes = new Map<string, string[]>();
      dados.convidados.forEach((p) => {
        const chave = normalizar(p.nome).replace(/\s+/g, " ");
        existentes.set(chave, [
          ...(existentes.get(chave) ?? []),
          `${p.nome} · ${p.conjunto}`,
        ]);
      });
      const vistos = new Map<string, string[]>();
      const unicos: LinhaImportacao[] = [];
      const repetidos: DuplicidadeImportacao[] = [];
      for (const linha of linhas) {
        const chave = normalizar(linha.nome).replace(/\s+/g, " "),
          iguais = [
            ...(existentes.get(chave) ?? []),
            ...(vistos.get(chave) ?? []),
          ];
        if (iguais.length)
          repetidos.push({ linha, encontrados: iguais, criar: false });
        else unicos.push(linha);
        vistos.set(chave, [
          ...(vistos.get(chave) ?? []),
          `${linha.nome} · nesta planilha`,
        ]);
      }
      const importados = await enviarImportacao(unicos);
      await recarregar();
      if (repetidos.length) {
        setImportadosAntesDuplicidades(importados);
        setDuplicidades(repetidos);
        setAviso("");
      } else
        setAviso(
          `${importados} ${importados === 1 ? "convidado importado" : "convidados importados"} com códigos gerados automaticamente.`,
        );
    } catch (erro) {
      setAviso(
        erro instanceof Error ? erro.message : "Não foi possível importar.",
      );
    } finally {
      setImportando(false);
    }
  }
  async function concluirDuplicidades() {
    setImportando(true);
    try {
      const escolhidos = duplicidades
        .filter((d) => d.criar)
        .map((d) => d.linha);
      const adicionais = await enviarImportacao(escolhidos);
      const total = importadosAntesDuplicidades + adicionais;
      setDuplicidades([]);
      setImportadosAntesDuplicidades(0);
      await recarregar();
      setAviso(
        `${total} ${total === 1 ? "convidado importado" : "convidados importados"}. ${duplicidades.length - escolhidos.length} nome(s) idêntico(s) foram reconhecidos como a mesma pessoa.`,
      );
    } catch (erro) {
      setAviso(
        erro instanceof Error
          ? erro.message
          : "Não foi possível concluir a importação.",
      );
    } finally {
      setImportando(false);
    }
  }

  async function importarPresentes(file: File) {
    setImportando(true);
    try {
      setAviso("");
      const workbook = XLSX.read(await file.arrayBuffer(), { type: "array" });
      const folha = workbook.Sheets[workbook.SheetNames[0]];
      const tabela = XLSX.utils.sheet_to_json<(string | number)[]>(folha, { header: 1, defval: "", raw: false });
      if (tabela.length < 2) throw new Error("A planilha precisa ter cabeçalho e pelo menos um presente.");
      const cab = tabela[0].map((v) => normalizar(String(v)).replace(/\s+/g, "_"));
      const idx = (...nomes: string[]) => nomes.map((n) => cab.indexOf(n)).find((i) => i >= 0) ?? -1;
      const nomeIdx = idx("nome"), categoriaIdx = idx("categoria"), valorIdx = idx("valor"), fotosIdx = idx("links_de_fotos", "links_fotos", "fotos");
      const descricaoIdx = idx("descricao"), quantidadeIdx = idx("quantidade");
      if ([nomeIdx, categoriaIdx, valorIdx, fotosIdx].some((i) => i < 0)) throw new Error('Use as colunas obrigatórias: "Nome", "Categoria", "Valor" e "Links de fotos".');
      const linhas: LinhaPresenteImportacao[] = tabela.slice(1).map((r) => ({
        nome: String(r[nomeIdx] ?? "").trim(),
        categoria: String(r[categoriaIdx] ?? "").trim(),
        valor: Number(String(r[valorIdx] ?? "0").replace(/[^0-9,.-]/g, "").replace(/\./g, "").replace(",", ".")),
        links_fotos: String(r[fotosIdx] ?? "").split(/[\n;,]+/).map((v) => v.trim()).filter(Boolean),
        descricao: descricaoIdx >= 0 ? String(r[descricaoIdx] ?? "").trim() : "",
        quantidade: Math.max(1, Math.trunc(Number(quantidadeIdx >= 0 ? r[quantidadeIdx] : 1) || 1)),
      })).filter((p) => p.nome.length >= 2 && p.valor >= 0);
      if (!linhas.length) throw new Error("Nenhum presente válido foi encontrado.");
      const listaAtual = presentes.length ? presentes : await carregarPresentes();
      const existentes = new Set(listaAtual.map((p) => normalizar(p.nome)));
      const vistos = new Set<string>();
      const aprovados: LinhaPresenteImportacao[] = [];
      for (const linha of linhas) {
        const chave = normalizar(linha.nome);
        if ((existentes.has(chave) || vistos.has(chave)) && !window.confirm(`O presente “${linha.nome}” já existe. Deseja criar outro item com o mesmo nome?`)) continue;
        aprovados.push(linha);
        vistos.add(chave);
      }
      if (!aprovados.length) throw new Error("Nenhum novo presente foi selecionado para importação.");
      const resposta = await fetch("/api/convite", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "importar_presentes", codigo, linhas: aprovados }) });
      const resultado = await resposta.json();
      if (!resposta.ok) throw new Error(resultado.error || "Não foi possível importar os presentes.");
      await carregarPresentes();
      setAviso(`${resultado.importados} presente(s) importado(s) com sucesso.`);
    } catch (erro) {
      setAviso(erro instanceof Error ? erro.message : "Não foi possível importar os presentes.");
    } finally { setImportando(false); }
  }

  if (pagina === "convidados")
    return (
      <div className="panel admin-page guest-admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">
          {assessoria ? "Área da Assessoria" : "Área dos Noivos"}
        </p>
        <h1>Lista completa de convidados</h1>
        <div className="admin-actions">
          {!assessoria && (
            <button
              className="primary"
              onClick={() => {
                setEditando(null);
                setNome("");
                setFuncao("");
                setGrupo("");
                setGestor(true);
              }}
            >
              Adicionar pessoa
            </button>
          )}
          {!assessoria && (
            <>
              <button className="secondary" onClick={() => setPagina("exportar")}>
                Exportar convites
              </button>
              <button
                className="secondary"
                onClick={() =>
                  baixarCsv(
                "convidados.csv",
                [
                  "nome",
                  "codigo_individual",
                  "codigo_conjunto",
                  "conjunto",
                  "pode_gerenciar",
                  "status",
                  "funcao",
                "nivel_acesso",
                  "visualizado_em",
                ],
                dados.convidados.map((p) => [
                  p.nome,
                  p.codigo_individual,
                  p.codigo,
                  p.conjunto,
                  p.pode_gerenciar,
                  p.status,
                  p.funcao,
                  p.nivel_acesso,
                  p.visualizado_em,
                ]),
                  )
                }
              >
                Baixar para Excel
              </button>
            </>
          )}
          {!assessoria && (
            <label className="secondary file-button">
              {importando ? "Importando..." : "Importar CSV ou Excel"}
              <input
                type="file"
                accept=".csv,.xlsx,.xls,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel"
                disabled={importando}
                onChange={(e) =>
                  e.target.files?.[0] && importar(e.target.files[0])
                }
              />
            </label>
          )}
        </div>
        {!assessoria && (
          <div className="admin-form guest-limit-form">
            <label>
              Idade máxima para criança{" "}
              <input
                type="number"
                min={0}
                max={17}
                value={idadeLimite}
                onChange={(e) => setIdadeLimite(Number(e.target.value))}
              />
            </label>
            <button className="secondary" onClick={salvarIdadeLimite}>
              Salvar limite
            </button>
            <small>Padrão: 8 anos.</small>
          </div>
        )}
        {(!assessoria || editando) && (
          <form className="admin-form guest-editor-form" onSubmit={salvar}>
            <input
              placeholder="Nome da pessoa"
              value={nome}
              onChange={(e) => setNome(e.target.value)}
              required
              disabled={assessoria}
            />
            {!assessoria && (
              <label>
                Código individual {editando ? "" : "(opcional)"}
                <input
                  value={codigoIndividual}
                  onChange={(e) => setCodigoIndividual(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6))}
                  placeholder={editando ? undefined : "Gerado automaticamente se vazio"}
                  minLength={6}
                  maxLength={6}
                  pattern="[A-Z0-9]{6}"
                  required={Boolean(editando)}
                  autoComplete="off"
                />
                <small>Use exatamente 6 letras ou números. A disponibilidade será confirmada ao salvar.</small>
              </label>
            )}
            {editando ? (
              <select
                value={grupo}
                onChange={(e) => setGrupo(e.target.value)}
                required
                disabled={assessoria}
              >
                <option value="">Selecione o grupo</option>
                {grupos.map((g) => (
                  <option key={g.id} value={g.codigo}>
                    {g.titulo} · {g.codigo}
                  </option>
                ))}
              </select>
            ) : (
              <p className="form-note">
                Será criado um grupo individual com o mesmo código individual
                desta pessoa. Depois, você poderá associá-la a outro grupo pela
                edição.
              </p>
            )}
            <select value={funcao} onChange={(e) => setFuncao(e.target.value)}>
              <option value="">Convidado</option>
              {FUNCOES.slice(1).map((f) => (
                <option key={f}>{f}</option>
              ))}
            </select>
            <label>
              Convidado de{" "}
              <select
                value={origem}
                onChange={(e) => setOrigem(e.target.value as OrigemConvidado)}
                disabled={assessoria}
              >
                <option value="nao_classificado">Não classificado</option>
                <option value="noivo">Noivo</option>
                <option value="noiva">Noiva</option>
                <option value="ambos">Ambos</option>
              </select>
            </label>
            {!assessoria && (
              <label className="guest-checkbox">
                <input
                  type="checkbox"
                  checked={crianca}
                  onChange={(e) => setCrianca(e.target.checked)}
                />{" "}
                Marcar como criança
              </label>
            )}
            {!assessoria && editando && (
              <label className="guest-checkbox">
                <input
                  type="checkbox"
                  checked={gestor}
                  onChange={(e) => setGestor(e.target.checked)}
                />{" "}
                Pode gerenciar
              </label>
            )}
            <button className="primary">
              {editando ? "Salvar alterações" : "Adicionar"}
            </button>
          </form>
        )}
        <div className="guest-search">
          <label htmlFor="pesquisa-convidado">Pesquisar convidado</label>
          <input
            id="pesquisa-convidado"
            type="search"
            value={pesquisa}
            onChange={(e) => setPesquisa(e.target.value)}
            placeholder="Nome, código, grupo ou função"
          />
          <small>
            {convidadosFiltrados.length} de {dados.convidados.length} convidados
          </small>
        </div>
        {aviso && (
          <p
            className={
              aviso.includes("atualizado") || aviso.includes("importado")
                ? "success-note"
                : "error"
            }
          >
            {aviso}
          </p>
        )}
        <div className="admin-table guest-admin-table">
          <div className="table-head">
            <span>Pessoa</span>
            <span>Conjunto</span>
            <span>Presença</span>
            <span>Visualização</span>
            <span>Prazo</span>
            <span>Ações</span>
          </div>
          {convidadosFiltrados.map((p) => (
            <div className="table-row" key={p.id}>
              <span>
                <b>{p.nome}</b>
                <small>
                  {p.crianca
                    ? `Criança${p.idade !== null ? ` · ${p.idade} anos` : ""}`
                    : p.funcao || "Convidado"}{" "}
                  · código {p.codigo_individual}
                </small>
              </span>
              <span>
                <b>{p.conjunto}</b>
                <small>conjunto {p.codigo}</small>
              </span>
              <span>
                <select
                  value={p.status}
                  onChange={(e) =>
                    administrar("presenca", {
                      id: p.id,
                      status: e.target.value,
                    })
                  }
                >
                  <option value="aguardando">Aguardando</option>
                  <option value="confirmado">Confirmado</option>
                  <option value="expirado">Expirado</option>
                </select>
                {p.resposta === "nao" && (
                  <small>Informou que não comparecerá</small>
                )}
              </span>
              <span>
                <b>{p.visualizado_em ? "Visualizado" : "Não visualizado"}</b>
                <small>{p.visualizado_em ? new Date(p.visualizado_em).toLocaleString("pt-BR") : "Ainda não abriu o convite individual"}</small>
              </span>
              <span>
                <b>
                  {p.sem_expiracao
                    ? "Sem expiração"
                    : p.expirado
                      ? "EXPIRADO"
                      : "Ativo"}
                </b>
                <small>
                  {!p.sem_expiracao && p.expira_em
                    ? new Date(p.expira_em).toLocaleString("pt-BR")
                    : "Prazo removido"}
                </small>
                {!assessoria && (
                  <>
                    <input
                      aria-label={`Nova data limite de ${p.nome}`}
                      type="datetime-local"
                      onChange={(e) =>
                        e.target.value &&
                        expirar(
                          p.convite_id,
                          "definir_data",
                          new Date(e.target.value).toISOString(),
                        )
                      }
                    />
                    <div className="expiry-actions">
                      <button
                        onClick={() => expirar(p.convite_id, "resetar_7_dias")}
                      >
                        Resetar 7 dias
                      </button>
                      <button onClick={() => expirar(p.convite_id, "expirar")}>
                        Expirar
                      </button>
                      <button
                        onClick={() => expirar(p.convite_id, "retirar_expiracao")}
                      >
                        Sem expiração
                      </button>
                    </div>
                  </>
                )}
              </span>
              <span>
                <button onClick={() => abrirEdicao(p)}>
                  Editar função{assessoria ? "" : " e dados"}
                </button>
                {!assessoria && (
                  <button
                    className="danger"
                    onClick={() =>
                      confirm(`Remover ${p.nome}?`) &&
                      administrar("remover", { id: p.id })
                    }
                  >
                    Retirar
                  </button>
                )}
              </span>
            </div>
          ))}
        </div>
        {!convidadosFiltrados.length && (
          <div className="empty-state">Nenhum convidado encontrado.</div>
        )}
        {!!duplicidades.length && (
          <div className="modal-backdrop" role="presentation">
            <section
              className="duplicate-modal"
              role="dialog"
              aria-modal="true"
              aria-labelledby="duplicate-title"
            >
              <p className="eyebrow">Revisão da importação</p>
              <h2 id="duplicate-title">Nomes idênticos encontrados</h2>
              <p>
                Os demais convidados já foram processados. Confirme
                individualmente se cada linha abaixo representa outra pessoa.
              </p>
              <div className="duplicate-list">
                {duplicidades.map((d, i) => (
                  <article key={`${d.linha.nome}-${i}`}>
                    <div>
                      <b>{d.linha.nome}</b>
                      <small>Já encontrado: {d.encontrados.join("; ")}</small>
                    </div>
                    <fieldset>
                      <legend>Esta linha é:</legend>
                      <label>
                        <input
                          type="radio"
                          name={`duplicado-${i}`}
                          checked={!d.criar}
                          onChange={() =>
                            setDuplicidades((atual) =>
                              atual.map((x, j) =>
                                j === i ? { ...x, criar: false } : x,
                              ),
                            )
                          }
                        />{" "}
                        A mesma pessoa — não importar novamente
                      </label>
                      <label>
                        <input
                          type="radio"
                          name={`duplicado-${i}`}
                          checked={d.criar}
                          onChange={() =>
                            setDuplicidades((atual) =>
                              atual.map((x, j) =>
                                j === i ? { ...x, criar: true } : x,
                              ),
                            )
                          }
                        />{" "}
                        Outra pessoa com nome igual — gerar novo convite
                      </label>
                    </fieldset>
                  </article>
                ))}
              </div>
              <button
                className="primary"
                disabled={importando}
                onClick={concluirDuplicidades}
              >
                {importando ? "Concluindo..." : "Confirmar todas e concluir"}
              </button>
            </section>
          </div>
        )}
      </div>
    );

  if (pagina === "exportar")
    return (
      <>
        <button className="back-link" onClick={() => setPagina("convidados")}>
          ← Voltar à lista de convidados
        </button>
        <ExportarConvites
          pessoas={dados.convidados}
          evento={evento}
          configuracoes={configuracoes}
        />
      </>
    );

  if (pagina === "controles")
    return <ControlesAdministrativos dados={dados} codigo={codigo} voltar={() => setPagina("geral")} />;

  if (pagina === "pagamentos")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Administração</p>
        <h1>Pagamentos — Mercado Pago</h1>
        <p>
          Acompanhe as transações e configure o Checkout Pro. O Access Token é
          protegido no servidor.
        </p>
        {mp?.ativa && (
          <div className="payment-status connected">
            <b>✓ Conexão ativa</b>
            <span>
              Conta {mp.conta_email || mp.conta_id} · verificada{" "}
              {mp.verificada_em
                ? new Date(mp.verificada_em).toLocaleString("pt-BR")
                : "agora"}
            </span>
          </div>
        )}
        <section className="cpf-settings">
          <h2>Recolhimento de CPF</h2>
          <form className="payment-config-form" onSubmit={salvarConfiguracaoCpf}>
            <label className="switch-label">
              <input type="checkbox" checked={recolherCpf} onChange={(e) => setRecolherCpf(e.target.checked)} />
              Solicitar CPF quando o total acumulado atingir o limite
            </label>
            <label>
              Valor mínimo acumulado (R$)
              <input type="number" min="0.01" step="0.01" value={cpfMinimo} onChange={(e) => setCpfMinimo(Number(e.target.value))} disabled={!recolherCpf} />
            </label>
            <small>O cálculo soma pagamentos anteriores aprovados da pessoa ao valor do carrinho atual. O CPF é criptografado e o aceite da Política de Privacidade é registrado.</small>
            <button className="primary" disabled={mpCarregando}>Salvar regra de CPF</button>
          </form>
        </section>
        <section className="payments-section">
          <div className="payments-heading">
            <div>
              <h2>Lista de pagamentos</h2>
              <p>Status atualizado pelas notificações do Mercado Pago.</p>
            </div>
            <button
              className="secondary"
              disabled={mpCarregando}
              onClick={carregarMercadoPago}
            >
              Atualizar
            </button>
          </div>
          <div className="payments-table">
            <div className="payment-row payment-head">
              <span>Pessoa</span>
              <span>Data e meio</span>
              <span>Presentes</span>
              <span>Status</span>
              <span>Ação</span>
            </div>
            {pagamentos.map((p) => {
              const rotulo =
                p.status === "confirmado"
                  ? "Aprovado"
                  : p.status === "rejeitado"
                    ? "Rejeitado"
                    : p.status === "reembolsado"
                      ? "Reembolsado"
                      : "Em processamento";
              return (
                <article className="payment-row" key={p.id}>
                  <span>
                    <b>{p.pagador_nome}</b>
                    <small>
                      {p.pagador_email || `Convite ${p.convite_codigo || "—"}`}
                    </small>
                    {p.valor != null && (
                      <strong>
                        {p.valor.toLocaleString("pt-BR", {
                          style: "currency",
                          currency: "BRL",
                        })}
                      </strong>
                    )}
                  </span>
                  <span>
                    {new Date(p.criado_em).toLocaleString("pt-BR")}
                    <small>{p.meio_pagamento}</small>
                  </span>
                  <span>
                    {p.itens.map((i, n) => (
                      <small key={`${i.nome}-${n}`}>
                        {i.quantidade}× {i.nome}
                      </small>
                    ))}
                  </span>
                  <span>
                    <i className={`payment-badge ${p.status}`}>{rotulo}</i>
                  </span>
                  <span>
                    {p.status === "confirmado" && p.pagamento_id ? (
                      <button
                        className="danger"
                        disabled={mpCarregando}
                        onClick={() => reembolsarPagamento(p)}
                      >
                        Reembolsar
                      </button>
                    ) : (
                      <small>
                        {p.reembolsado_em
                          ? new Date(p.reembolsado_em).toLocaleString("pt-BR")
                          : "—"}
                      </small>
                    )}
                  </span>
                </article>
              );
            })}
            {!pagamentos.length && (
              <div className="empty-state">Nenhum pagamento registrado.</div>
            )}
          </div>
        </section>
        <details className="payment-settings">
          <summary>Configurar integração</summary>
          <form className="payment-config-form" onSubmit={salvarMercadoPago}>
            <label>
              Ambiente
              <select
                value={mpAmbiente}
                onChange={(e) =>
                  setMpAmbiente(e.target.value as "teste" | "producao")
                }
              >
                <option value="teste">Teste</option>
                <option value="producao">Produção</option>
              </select>
            </label>
            <label>
              Public Key
              <input
                value={mpPublicKey}
                onChange={(e) => setMpPublicKey(e.target.value)}
                placeholder="APP_USR-..."
                autoComplete="off"
              />
            </label>
            <label>
              Access Token
              <input
                type="password"
                value={mpToken}
                onChange={(e) => setMpToken(e.target.value)}
                placeholder={mp?.access_token_mascarado || "APP_USR-..."}
                required
                autoComplete="new-password"
              />
            </label>
            <small>
              Ao salvar, o sistema testa as credenciais diretamente no Mercado
              Pago.
            </small>
            <div className="admin-actions">
              <button className="primary" disabled={mpCarregando}>
                {mpCarregando
                  ? "Verificando conexão..."
                  : "Testar, salvar e ativar"}
              </button>
              {mp?.ativa && (
                <button
                  type="button"
                  className="secondary"
                  onClick={desativarMercadoPago}
                >
                  Desativar pagamentos
                </button>
              )}
            </div>
          </form>
        </details>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
        <section className="management-note">
          <b>Webhook</b>
          <p>
            Cadastre no painel do Mercado Pago esta URL para eventos de
            pagamento:
          </p>
          <code>
            {configuracoes.url_base.replace(/\/+$/, "")}
            /api/mercado-pago/webhook
          </code>
        </section>
      </div>
    );

  if (pagina === "configuracoes")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Administração</p>
        <h1>Configurações gerais</h1>
        <form className="admin-form admin-form-settings" onSubmit={salvarConfiguracoes}>
          <label>
            URL base do site{" "}
            <input
              type="url"
              value={configuracoes.url_base}
              onChange={(e) =>
                setConfiguracoes({ ...configuracoes, url_base: e.target.value })
              }
              required
            />
          </label>
          <small>
            Exemplo dos convites: {configuracoes.url_base.replace(/\/+$/, "")}
            /c/CODIGO e {configuracoes.url_base.replace(/\/+$/, "")}/g/CODIGO
          </small>
          <label>
            Título do site{" "}
            <input
              value={configuracoes.titulo_site}
              onChange={(e) =>
                setConfiguracoes({
                  ...configuracoes,
                  titulo_site: e.target.value,
                })
              }
              required
            />
          </label>
          <label>
            Prazo padrão dos novos convites (dias){" "}
            <input
              type="number"
              min={1}
              max={365}
              value={configuracoes.dias_expiracao_padrao}
              onChange={(e) =>
                setConfiguracoes({
                  ...configuracoes,
                  dias_expiracao_padrao: Number(e.target.value),
                })
              }
            />
          </label>
          <label>
            Orientação para confirmar presença{" "}
            <textarea
              rows={3}
              value={configuracoes.mensagem_confirmacao}
              onChange={(e) =>
                setConfiguracoes({
                  ...configuracoes,
                  mensagem_confirmacao: e.target.value,
                })
              }
            />
          </label>
          <button className="primary">Salvar configurações</button>
        </form>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
      </div>
    );

  if (pagina === "configuracoes_presentes")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Administração</p>
        <h1>Configurações de presentes</h1>
        <p>Crie, renomeie, ordene ou desative as categorias da lista de presentes.</p>
        <h2>Categorias dos presentes</h2>
        <form className="admin-form admin-form-category" onSubmit={adicionarCategoria}>
          <input
            value={novaCategoria}
            onChange={(e) => setNovaCategoria(e.target.value)}
            placeholder="Nova categoria"
            required
          />
          <button className="primary">Adicionar categoria</button>
        </form>
        <div className="group-list">
          {categorias.map((c) => (
            <article key={c.id}>
              <input
                defaultValue={c.nome}
                aria-label={`Nome da categoria ${c.nome}`}
                onBlur={(e) =>
                  e.target.value.trim() !== c.nome &&
                  acaoConfiguracao("editar_categoria", {
                    id: c.id,
                    nome: e.target.value.trim(),
                  })
                }
              />
              <div className="expiry-actions">
                <button
                  onClick={() =>
                    acaoConfiguracao("mover_categoria", {
                      id: c.id,
                      direcao: -1,
                    })
                  }
                >
                  ↑
                </button>
                <button
                  onClick={() =>
                    acaoConfiguracao("mover_categoria", {
                      id: c.id,
                      direcao: 1,
                    })
                  }
                >
                  ↓
                </button>
                <button
                  className="danger"
                  onClick={async () => {
                    if (
                      confirm(`Desativar a categoria ${c.nome}?`) &&
                      (await acaoConfiguracao("desativar_categoria", {
                        id: c.id,
                      }))
                    )
                      setCategorias(
                        (await carregarDadosAuxiliares()).categorias,
                      );
                  }}
                >
                  Desativar
                </button>
              </div>
            </article>
          ))}
        </div>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
      </div>
    );

  if (pagina === "grupos")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Área dos Noivos</p>
        <h1>Grupos de convidados</h1>
        <p>
          Crie grupos como “Família de Jorge” ou “Amigos do IFBA”. Depois,
          associe as pessoas ao grupo na lista de convidados.
        </p>
        <form className="admin-form group-form" onSubmit={salvarGrupo}>
          <input
            aria-label="Código do grupo"
            placeholder="Código com 6 caracteres"
            value={codigoGrupo}
            onChange={(e) =>
              setCodigoGrupo(
                e.target.value
                  .toUpperCase()
                  .replace(/[^A-Z0-9]/g, "")
                  .slice(0, 6),
              )
            }
            minLength={6}
            maxLength={6}
            required
          />
          <input
            aria-label="Título do grupo"
            placeholder="Título do grupo"
            value={tituloGrupo}
            onChange={(e) => setTituloGrupo(e.target.value)}
            maxLength={100}
            required
          />
          <label>
            Crianças adicionais permitidas{" "}
            <input
              type="number"
              min={0}
              max={20}
              value={criancasExtras}
              onChange={(e) => setCriancasExtras(Number(e.target.value))}
            />
          </label>
          <button className="primary">
            {grupoEditando ? "Salvar grupo" : "Criar grupo"}
          </button>
          {grupoEditando && (
            <button
              type="button"
              className="secondary"
              onClick={() => {
                setGrupoEditando(null);
                setCodigoGrupo("");
                setTituloGrupo("");
                setCriancasExtras(0);
              }}
            >
              Cancelar
            </button>
          )}
        </form>
        {aviso && <p className="error">{aviso}</p>}
        <div className="group-list">
          {grupos.map((g) => (
            <article key={g.id}>
              <div>
                <b>{g.titulo}</b>
                <small>
                  Código {g.codigo} · {g.total}{" "}
                  {g.total === 1 ? "pessoa" : "pessoas"} · crianças adicionais:{" "}
                  {g.criancas_adicionais_usadas}/{g.criancas_adicionais_limite}
                </small>
              </div>
              {g.protegido && dados.perfil === "noivos" ? (
                <small>Grupo protegido</small>
              ) : (
                <button
                  onClick={() => {
                    setGrupoEditando(g);
                    setCodigoGrupo(g.codigo);
                    setTituloGrupo(g.titulo);
                    setCriancasExtras(g.criancas_adicionais_limite);
                  }}
                >
                  Editar
                </button>
              )}
            </article>
          ))}
        </div>
      </div>
    );

  if (pagina === "mensagens")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Área dos Noivos</p>
        <h1>Caixa de mensagens</h1>
        <p>Somente mensagens escritas pelos convidados ao confirmar presença ou assinar um presente.</p>
        <div className="message-list">
          {dados.mensagens?.length ? (
            dados.mensagens.map((m, i) => (
              <article key={`${m.codigo}-${m.atualizado_em}-${i}`}>
                <div className="message-meta">
                  <b>{m.grupo}</b>
                  <small>
                    {m.codigo} ·{" "}
                    {new Date(m.atualizado_em).toLocaleString("pt-BR")}
                  </small>
                </div>
                <p>{m.mensagem}</p>
              </article>
            ))
          ) : (
            <div className="empty-state">
              Nenhuma mensagem recebida até o momento.
            </div>
          )}
        </div>
      </div>
    );

  if (pagina === "notificacoes")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>← Voltar à visão geral</button>
        <p className="eyebrow">Área dos Noivos</p>
        <h1>Notificações</h1>
        <p>Alterações de presença e demais eventos automáticos do sistema.</p>
        <div className="message-list">
          {dados.notificacoes?.length ? dados.notificacoes.map((n,i)=><article key={`${n.codigo}-${n.criado_em}-${i}`}><div className="message-meta"><b>{n.grupo}</b><small>{n.codigo} · {new Date(n.criado_em).toLocaleString("pt-BR")}</small></div><p>{n.mensagem}</p></article>):<div className="empty-state">Nenhuma notificação até o momento.</div>}
        </div>
      </div>
    );

  if (pagina === "senha")
    return (
      <div className="panel admin-page">
        {!dados.conta.exige_troca_senha && (
          <button className="back-link" onClick={() => setPagina("geral")}>
            ← Voltar à visão geral
          </button>
        )}
        <p className="eyebrow">Segurança</p>
        <h1>Alterar minha senha</h1>
        <p>Confirme a senha anterior para definir uma nova.</p>
        <form className="admin-form" onSubmit={alterarSenha}>
          <input
            type="password"
            placeholder="Senha atual"
            value={senhaAtual}
            onChange={(e) => setSenhaAtual(e.target.value)}
            required
          />
          <input
            type="password"
            minLength={8}
            placeholder="Nova senha"
            value={novaSenha}
            onChange={(e) => setNovaSenha(e.target.value)}
            required
          />
          <input
            type="password"
            minLength={8}
            placeholder="Confirmar nova senha"
            value={confirmaNovaSenha}
            onChange={(e) => setConfirmaNovaSenha(e.target.value)}
            required
          />
          <button className="primary">Alterar senha</button>
        </form>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
      </div>
    );

  if (pagina === "evento")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Informações do convite</p>
        <h1>Data e local do casamento</h1>
        <form className="admin-form admin-form-event" onSubmit={salvarEvento}>
          <label>
            Data{" "}
            <input
              type="date"
              value={evento.data}
              onChange={(e) => setEvento({ ...evento, data: e.target.value })}
              required
            />
          </label>
          <label>
            Hora{" "}
            <input
              type="time"
              value={evento.hora}
              onChange={(e) => setEvento({ ...evento, hora: e.target.value })}
              required
            />
          </label>
          <label>
            Cidade{" "}
            <input
              value={evento.cidade}
              onChange={(e) => setEvento({ ...evento, cidade: e.target.value })}
              required
            />
          </label>
          <label>
            Nome do espaço{" "}
            <input
              value={evento.nome_espaco}
              onChange={(e) =>
                setEvento({ ...evento, nome_espaco: e.target.value })
              }
              required
            />
          </label>
          <label>
            Endereço completo{" "}
            <input
              value={evento.endereco}
              onChange={(e) =>
                setEvento({ ...evento, endereco: e.target.value })
              }
              required
            />
          </label>
          <label>
            Link do Google Maps{" "}
            <input
              type="url"
              value={evento.link_maps ?? ""}
              onChange={(e) =>
                setEvento({ ...evento, link_maps: e.target.value || null })
              }
              placeholder="https://maps.google.com/..."
            />
          </label>
          <label>
            <input
              type="checkbox"
              checked={evento.local_liberado}
              onChange={(e) =>
                setEvento({ ...evento, local_liberado: e.target.checked })
              }
            />{" "}
            Ativar e tornar o endereço visível
          </label>
          <small>
            Ao ativar e salvar, o nome do espaço, o endereço e o Google Maps
            ficarão visíveis no convite e na página inicial para todos. Enquanto
            estiver desativado, será exibido “Endereço: Aguardando a liberação”.
          </small>
          <button className="primary">Salvar informações</button>
        </form>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
      </div>
    );

  if (pagina === "organizacao" && admin)
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Administração</p>
        <h1>Organização</h1>
        <p>
          Noivos, assessoria e administradores ficam separados da lista de
          convidados.
        </p>
        {admin && (
          <form
            className="admin-form organization-form"
            onSubmit={async (e) => {
              e.preventDefault();
              const ok = await administrarOrganizacao(
                orgEditando ? "editar" : "criar",
                {
                  id: orgEditando?.id,
                  nome: orgNome,
                  usuario: orgUsuario,
                  codigo: orgCodigo || null,
                  funcao: orgFuncao,
                  administrador: orgAdmin,
                },
              );
              if (ok) {
                setOrgEditando(null);
                setOrgNome("");
                setOrgUsuario("");
                setOrgCodigo("");
                setOrgFuncao("assessoria");
                setOrgAdmin(false);
              }
            }}
          >
            <input
              placeholder="Nome"
              value={orgNome}
              onChange={(e) => setOrgNome(e.target.value)}
              required
            />
            <input
              placeholder="Usuário"
              value={orgUsuario}
              onChange={(e) =>
                setOrgUsuario(
                  e.target.value.toLowerCase().replace(/[^a-z0-9._-]/g, ""),
                )
              }
              required
            />
            <label>
              Código de acesso
              <input
                placeholder={
                  orgEditando
                    ? "Código com 6 caracteres"
                    : "Deixe vazio para gerar automaticamente"
                }
                value={orgCodigo}
                onChange={(e) =>
                  setOrgCodigo(
                    e.target.value
                      .toUpperCase()
                      .replace(/[^A-Z0-9]/g, "")
                      .slice(0, 6),
                  )
                }
                minLength={orgCodigo ? 6 : undefined}
                maxLength={6}
                pattern="[A-Z0-9]{6}"
                required={Boolean(orgEditando)}
                autoComplete="off"
              />
              <small>
                Use 6 letras ou números. O sistema verifica se o código está
                disponível antes de salvar.
              </small>
            </label>
            <select
              value={orgFuncao}
              onChange={(e) =>
                setOrgFuncao(e.target.value as Organizacao["funcao"])
              }
            >
              <option value="noivo">Noivo</option>
              <option value="noiva">Noiva</option>
              <option value="assessoria">Assessoria</option>
              <option value="administrador">Administrador</option>
            </select>
            <label className="organization-checkbox">
              <input
                type="checkbox"
                checked={orgAdmin}
                onChange={(e) => setOrgAdmin(e.target.checked)}
              />{" "}
              Poderes administrativos
            </label>
            <button className="primary">
              {orgEditando ? "Salvar" : "Criar usuário"}
            </button>
          </form>
        )}
        {credenciaisGeradas && (
          <p className="success-note">
            {credenciaisGeradas.codigo && (
              <>
                Código de acesso: <b>{credenciaisGeradas.codigo}</b>
              </>
            )}
            {credenciaisGeradas.codigo &&
              credenciaisGeradas.senhaTemporaria && <br />}
            {credenciaisGeradas.senhaTemporaria && (
              <>
                Senha temporária: <b>{credenciaisGeradas.senhaTemporaria}</b> —
                informe ao usuário. No próximo acesso, ele deverá substituí-la.
              </>
            )}
          </p>
        )}
        {aviso && <p className="error">{aviso}</p>}
        <div className="group-list">
          {dados.organizacao?.map((o) => (
            <article key={o.id}>
              <div>
                <b>{o.nome}</b>
                <small>
                  {o.funcao} · usuário {o.usuario}
                  {o.codigo ? ` · código ${o.codigo}` : ""} ·{" "}
                  {o.senha_criada ? "senha criada" : "sem senha"}
                  {o.exige_troca_senha ? " · troca obrigatória" : ""}
                </small>
              </div>
              <div className="expiry-actions">
                {admin && !o.principal && (
                  <>
                    <button
                      onClick={() => {
                        setOrgEditando(o);
                        setOrgNome(o.nome);
                        setOrgUsuario(o.usuario);
                        setOrgCodigo(o.codigo ?? "");
                        setOrgFuncao(o.funcao);
                        setOrgAdmin(o.administrador);
                      }}
                    >
                      Editar
                    </button>
                    <button
                      onClick={() =>
                        confirm(`Gerar uma nova senha temporária para ${o.nome}?`) &&
                        administrarOrganizacao("resetar_senha", { id: o.id })
                      }
                    >
                      Resetar senha
                    </button>
                    <button
                      onClick={() => {
                        const senha = prompt(
                          "Defina a nova senha (mínimo 8 caracteres):",
                        );
                        if (senha)
                          administrarOrganizacao("definir_senha", {
                            id: o.id,
                            senha,
                          });
                      }}
                    >
                      Definir senha
                    </button>
                  </>
                )}
                {o.principal && <small>Administrador principal</small>}
              </div>
            </article>
          ))}
        </div>
      </div>
    );

  if (pagina === "presentes")
    return (
      <div className="panel admin-page">
        <button className="back-link" onClick={() => setPagina("geral")}>
          ← Voltar à visão geral
        </button>
        <p className="eyebrow">Área dos Noivos</p>
        <h1>Lista completa de presentes</h1>
        <div className="admin-actions">
          <button
            className="primary"
            disabled={carregandoPresentes}
            onClick={carregarPresentes}
          >
            {carregandoPresentes
              ? "Carregando..."
              : presentes.length
                ? "Atualizar itens"
                : "Carregar itens para editar"}
          </button>
          <button
            className="secondary"
            onClick={() =>
              baixarCsv(
                "presentes-assinados.csv",
                ["convidado", "codigo", "presente", "quantidade", "data"],
                dados.reservas.map((r) => [
                  r.convidado,
                  r.codigo,
                  r.presente,
                  r.quantidade,
                  r.criado_em,
                ]),
              )
            }
          >
            Baixar assinaturas para Excel
          </button>
          <label className="secondary file-button">
            {importando ? "Importando..." : "Importar lista de presentes"}
            <input type="file" accept=".csv,.xlsx,.xls,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel" disabled={importando} onChange={(e) => e.target.files?.[0] && importarPresentes(e.target.files[0])}/>
          </label>
        </div>
        {aviso && (
          <p className={aviso.includes("sucesso") ? "success-note" : "error"}>
            {aviso}
          </p>
        )}
        <div className="gift-admin-list">
          {presentes.map((p) => (
            <article key={p.id}>
              <div className="gift-admin-summary">
                <div className="gift-admin-thumbs">
                  {p.imagens?.length ? (
                    p.imagens.slice(0, 3).map((src, i) => (
                      <img
                        key={`${src}-${i}`}
                        src={src}
                        alt=""
                        onError={(e) => {
                          e.currentTarget.src = "/presente-padrao.png";
                        }}
                      />
                    ))
                  ) : (
                    <img
                      src="/presente-padrao.png"
                      alt="Imagem padrão do presente"
                    />
                  )}
                </div>
                <div>
                  <b>{p.nome}</b>
                  <small>
                    {p.quantidade_assinada} de {p.quantidade_total} assinados ·{" "}
                    {p.imagens?.length || 0} imagem(ns)
                  </small>
                  <select
                    aria-label={`Categoria de ${p.nome}`}
                    value={p.categoria_id ?? ""}
                    onChange={(e) => categoriaPresente(p.id, e.target.value)}
                  >
                    <option value="">Sem categoria</option>
                    {categorias.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.nome}
                      </option>
                    ))}
                  </select>
                </div>
                <button
                  onClick={() => {
                    setPresenteEditando(p.id);
                    setUrlsImagens((p.imagens ?? []).join("\n"));
                  }}
                >
                  Editar imagens
                </button>
              </div>
              {presenteEditando === p.id && (
                <div className="gift-image-editor">
                  <label htmlFor={`imagens-${p.id}`}>
                    Links das imagens — uma URL por linha
                  </label>
                  <textarea
                    id={`imagens-${p.id}`}
                    rows={5}
                    value={urlsImagens}
                    onChange={(e) => setUrlsImagens(e.target.value)}
                    placeholder={
                      "https://exemplo.com/imagem-1.jpg\nhttps://exemplo.com/imagem-2.jpg"
                    }
                  />
                  <small>
                    Até 10 imagens. Deixe vazio para usar a imagem padrão.
                  </small>
                  <div className="expiry-actions">
                    <button
                      className="primary"
                      onClick={() => salvarImagensPresente(p.id)}
                    >
                      Salvar imagens
                    </button>
                    <button
                      className="secondary"
                      onClick={() => {
                        setPresenteEditando(null);
                        setUrlsImagens("");
                      }}
                    >
                      Cancelar
                    </button>
                  </div>
                </div>
              )}
            </article>
          ))}
        </div>
        <h2>Presentes assinados</h2>
        <div className="signed-list">
          {dados.reservas.map((r) => (
            <article key={r.id}>
              <div>
                <b>{r.presente}</b>
                <small>
                  {r.convidado} · {r.codigo}
                </small>
              </div>
              <strong>{r.quantidade}</strong>
            </article>
          ))}
        </div>
      </div>
    );

  const cards = [
    ["Total de convidados", dados.convidados_total, "todos"],
    ["Confirmados", dados.confirmados, "sim"],
    ["Não comparecem", dados.nao_comparecem, "nao"],
    ["Aguardando resposta", dados.aguardando, "aguardando"],
    ["Presentes assinados", dados.presentes_assinados, "presentes"],
  ] as const;
  return (
    <div className="panel dashboard">
      <p className="eyebrow">
        {admin
          ? "Área do Administrador"
          : assessoria
            ? "Área da Assessoria"
            : "Área dos Noivos"}
      </p>
      <h1>Visão geral dos convidados</h1>
      <div className="dashboard-nav">
        <button className="primary" onClick={() => setPagina("convidados")}>
          Lista de convidados
        </button>
        {admin && (
          <button className="secondary" onClick={() => setPagina("organizacao")}>
            Organização
          </button>
        )}
        {!assessoria && (
          <button className="secondary" onClick={() => setPagina("evento")}>
            Data e local
          </button>
        )}
        <button className="secondary" onClick={() => setPagina("senha")}>
          Alterar minha senha
        </button>
        {!assessoria && (
          <>
            <button className="secondary" onClick={() => setPagina("grupos")}>
              Gerenciar grupos
            </button>
            <button
              className="secondary"
              onClick={() => setPagina("mensagens")}
            >
              Mensagens
              {dados.mensagens?.length ? ` (${dados.mensagens.length})` : ""}
            </button>
            <button className="secondary" onClick={() => setPagina("notificacoes")}>Notificações{dados.notificacoes?.length ? ` (${dados.notificacoes.length})` : ""}</button>
            <button
              className="secondary"
              onClick={() => {
                setPagina("presentes");
                void carregarPresentes();
              }}
            >
              Lista de presentes
            </button>
            {admin && (
              <>
                <button
                  className="secondary"
                  onClick={() => {
                    setPagina("configuracoes");
                  }}
                >
                  Configurações gerais
                </button>
                <button
                  className="secondary"
                  onClick={() => {
                    setPagina("configuracoes_presentes");
                    void carregarDadosAuxiliares();
                  }}
                >
                  Configurações de presentes
                </button>
                <button
                  className="secondary"
                  onClick={() => {
                    setPagina("pagamentos");
                    void carregarMercadoPago();
                  }}
                >
                  Pagamentos
                </button>
                <button className="secondary" onClick={() => setPagina("controles")}>
                  Controles e pré-evento
                </button>
              </>
            )}
          </>
        )}
      </div>
      <div className="metric-grid">
        {cards
          .filter(([, , f]) => !assessoria || f !== "presentes")
          .map(([l, v, f]) => (
            <button
              key={l}
              className={filtro === f ? "selected" : ""}
              onClick={() => setFiltro(f)}
            >
              <span>{l}</span>
              <b>{v}</b>
              <small>Ver relação</small>
            </button>
          ))}
      </div>
      <section className="detail-panel">
        <h2>
          {filtro === "presentes"
            ? "Presentes assinados"
            : filtro === "sim"
              ? "Convidados confirmados"
              : filtro === "nao"
                ? "Convidados que não comparecem"
              : filtro === "aguardando"
                ? "Aguardando resposta"
                : "Todos os convidados"}
        </h2>
        {filtro === "presentes" ? (
          <div className="signed-list">
            {dados.reservas.map((r) => (
              <article key={r.id}>
                <div>
                  <b>{r.convidado}</b>
                  <small>{r.presente}</small>
                </div>
                <strong>{r.quantidade}</strong>
              </article>
            ))}
          </div>
        ) : (
          <div className="people-list">
            {lista.map((p) => (
              <article key={p.id}>
                <div>
                  <b>{p.nome}</b>
                  <small>
                    {p.conjunto} · {p.codigo}
                  </small>
                </div>
                <span>
                  {p.resposta === "sim"
                    ? "Confirmado"
                    : p.resposta === "nao"
                      ? "Não comparece"
                      : p.status === "expirado"
                        ? "Expirado"
                        : "Aguardando"}
                </span>
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
