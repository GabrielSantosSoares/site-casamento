export type ConvidadoComFuncao = {
  id: string;
  nome: string;
  codigo_individual: string;
  pode_gerenciar: boolean;
  funcao: string | null;
  crianca: boolean;
};

export type CategoriaFuncao =
  | "padrinho"
  | "madrinha"
  | "amigo-noivo"
  | "demoiselle"
  | "porta-biblia"
  | "porta-alianca"
  | "pajem"
  | "daminha"
  | "florista"
  | "noivinho"
  | "outra";

export type CodigoManual =
  | "padrinhos"
  | "demoiselles"
  | "amigos-do-noivo"
  | "criancas";

export type AcessoFuncoes = {
  pessoa: ConvidadoComFuncao | null;
  funcaoPropria: ConvidadoComFuncao | null;
  criancasGerenciadas: ConvidadoComFuncao[];
  responsavelPorCrianca: boolean;
  manuais: CodigoManual[];
  temFuncao: boolean;
};

export const normalizarFuncao = (valor: string) =>
  valor
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();

export function categoriaFuncao(funcao: string): CategoriaFuncao {
  const valor = normalizarFuncao(funcao);
  if (valor.includes("madrinha")) return "madrinha";
  if (valor.includes("padrinh")) return "padrinho";
  if (valor.includes("amigo") && valor.includes("noivo")) return "amigo-noivo";
  if (valor.includes("demois")) return "demoiselle";
  if (valor.includes("biblia")) return "porta-biblia";
  if (valor.includes("alianca")) return "porta-alianca";
  if (valor.includes("florista")) return "florista";
  if (valor.includes("noivinh")) return "noivinho";
  if (valor.includes("pajem") || valor.includes("pagen") || valor.includes("pajen"))
    return "pajem";
  if (valor.includes("daminha")) return "daminha";
  return "outra";
}

export function ehFuncaoInfantil(funcao: string | null | undefined) {
  if (!funcao?.trim()) return false;
  const categoria = categoriaFuncao(funcao);
  return (
    [
      "porta-biblia",
      "porta-alianca",
      "pajem",
      "daminha",
      "florista",
      "noivinho",
    ] as CategoriaFuncao[]
  ).includes(categoria) || normalizarFuncao(funcao).includes("crianca");
}

export function ehCriancaDoCortejo(
  convidado: Pick<ConvidadoComFuncao, "funcao" | "crianca">,
) {
  return convidado.crianca || ehFuncaoInfantil(convidado.funcao);
}

export function manualDaFuncao(
  convidado: Pick<ConvidadoComFuncao, "funcao" | "crianca">,
): CodigoManual | null {
  if (!convidado.funcao?.trim()) return null;
  if (ehCriancaDoCortejo(convidado)) return "criancas";
  const categoria = categoriaFuncao(convidado.funcao);
  if (categoria === "padrinho" || categoria === "madrinha") return "padrinhos";
  if (categoria === "demoiselle") return "demoiselles";
  if (categoria === "amigo-noivo") return "amigos-do-noivo";
  if (
    ["porta-biblia", "porta-alianca", "pajem", "daminha", "florista", "noivinho"].includes(
      categoria,
    )
  )
    return "criancas";
  return null;
}

export function resolverAcessoFuncoes(
  codigo: string,
  convidados: ConvidadoComFuncao[],
  podeGerenciarGrupo = false,
): AcessoFuncoes {
  const codigoNormalizado = codigo.trim().toUpperCase();
  const pessoa =
    convidados.find(
      (convidado) =>
        convidado.codigo_individual?.trim().toUpperCase() === codigoNormalizado,
    ) ?? null;
  const funcaoPropria = pessoa?.funcao?.trim() ? pessoa : null;
  const podeResponderPorCrianca = Boolean(
    pessoa &&
      !ehCriancaDoCortejo(pessoa) &&
      (pessoa.pode_gerenciar || podeGerenciarGrupo),
  );
  const criancasGerenciadas = podeResponderPorCrianca
    ? convidados.filter(
        (convidado) =>
          convidado.id !== pessoa?.id &&
          ehCriancaDoCortejo(convidado) &&
          Boolean(convidado.funcao?.trim()),
      )
    : [];
  const manuais = new Set<CodigoManual>();
  if (funcaoPropria) {
    const manual = manualDaFuncao(funcaoPropria);
    if (manual) manuais.add(manual);
  }
  if (criancasGerenciadas.length) manuais.add("criancas");

  return {
    pessoa,
    funcaoPropria,
    criancasGerenciadas,
    responsavelPorCrianca: criancasGerenciadas.length > 0,
    manuais: [...manuais],
    temFuncao: Boolean(funcaoPropria || criancasGerenciadas.length),
  };
}

function artigoDaFuncao(funcao: string) {
  const categoria = categoriaFuncao(funcao);
  return ["madrinha", "demoiselle", "daminha", "florista"].includes(categoria)
    ? "nossa"
    : "nosso";
}

export function fraseMeuPapel(acesso: AcessoFuncoes) {
  const funcao = acesso.funcaoPropria?.funcao?.trim();
  if (funcao && acesso.responsavelPorCrianca) {
    return `Você é ${artigoDaFuncao(funcao)} ${funcao.toLowerCase()} e também responsável por criança do cortejo.`;
  }
  if (funcao) {
    return `Você é ${artigoDaFuncao(funcao)} ${funcao.toLowerCase()}.`;
  }
  if (acesso.responsavelPorCrianca) {
    return "Você é responsável por criança do cortejo.";
  }
  return "";
}

export function rotuloResumoFuncao(acesso: AcessoFuncoes) {
  return acesso.funcaoPropria?.funcao?.trim() ||
    (acesso.responsavelPorCrianca ? "Responsável por criança do cortejo" : "");
}
