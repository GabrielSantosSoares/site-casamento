"use client";

import {
  AcessoFuncoes,
  categoriaFuncao,
  CodigoManual,
  ConvidadoComFuncao,
  fraseMeuPapel,
} from "../lib/funcoes";

type GrupoOrientacao = {
  titulo: string;
  itens: string[];
};

type DetalhesFuncao = {
  apresentacao: string;
  traje: GrupoOrientacao[];
  orientacoes: string[];
};

const ARQUIVOS_MANUAIS: Record<
  CodigoManual,
  { titulo: string; arquivo: string }
> = {
  padrinhos: {
    titulo: "Manual dos Padrinhos",
    arquivo: "/manuais/manual-dos-padrinhos.pdf",
  },
  demoiselles: {
    titulo: "Manual das Demoiselles",
    arquivo: "/manuais/manual-das-demoiselles.pdf",
  },
  "amigos-do-noivo": {
    titulo: "Manual do Amigo do Noivo",
    arquivo: "/manuais/manual-do-amigo-do-noivo.pdf",
  },
  criancas: {
    titulo: "Manual das Crianças",
    arquivo: "/manuais/manual-das-criancas.pdf",
  },
};

const ORIENTACOES_GERAIS = [
  "Confira as informações do convite e acompanhe os comunicados da organização.",
  "Chegue com antecedência e procure a assessoria para receber as orientações de entrada.",
  "Participe com alegria, tranquilidade e atenção durante toda a cerimônia.",
  "Se precisar de ajuda no grande dia, fale com a assessoria ou com os noivos.",
];

function detalhesDaFuncao(convidado: ConvidadoComFuncao): DetalhesFuncao {
  const funcao = convidado.funcao?.trim() || "Criança do cortejo";
  const categoria = categoriaFuncao(funcao);

  if (convidado.crianca) {
    return {
      apresentacao:
        "A participação no cortejo foi preparada para ser leve, acolhedora e especial. O bem-estar da criança vem sempre em primeiro lugar.",
      traje: [
        {
          titulo: "Meninos",
          itens: [
            "Camisa branca",
            "Gravata-borboleta e suspensório azul serenity",
            "Calça preta",
            "Sapato social preto",
          ],
        },
        {
          titulo: "Meninas",
          itens: [
            "Vestido branco com laço azul",
            "Sapatilha ou sandália clara",
            "Acessórios discretos",
            "Tecido leve e sem estampas",
          ],
        },
      ],
      orientacoes: [
        "O responsável deve acompanhar os horários, ensaios e orientações da assessoria.",
        "Cheguem com antecedência para que a criança se familiarize com o local.",
        "A entrada será explicada e acompanhada pela equipe do casamento.",
        "A criança pode se divertir e se emocionar; não é necessário cobrar uma apresentação perfeita.",
      ],
    };
  }

  if (categoria === "madrinha") {
    return {
      apresentacao:
        "Como madrinha, você foi escolhida para testemunhar esta união e permanecer perto de nós em um dos momentos mais importantes da nossa história.",
      traje: [
        {
          titulo: "Traje da madrinha",
          itens: [
            "Vestido longo azul serenity",
            "Modelo elegante e delicado",
            "Tecido liso ou leve, sem estampas",
            "Acessórios são bem-vindos",
          ],
        },
      ],
      orientacoes: ORIENTACOES_GERAIS,
    };
  }

  if (categoria === "padrinho") {
    return {
      apresentacao:
        "Como padrinho, você foi escolhido para testemunhar esta união e apoiar a nova família que estamos formando.",
      traje: [
        {
          titulo: "Traje do padrinho",
          itens: [
            "Terno preto",
            "Camisa branca",
            "Gravata azul serenity",
            "Sapato social clássico",
            "Colete opcional",
          ],
        },
      ],
      orientacoes: ORIENTACOES_GERAIS,
    };
  }

  if (categoria === "demoiselle") {
    return {
      apresentacao:
        "Como demoiselle, sua presença próxima à noiva torna este momento ainda mais especial e representa carinho, amizade e apoio.",
      traje: [
        {
          titulo: "Traje da demoiselle",
          itens: [
            "Vestido longo em lavanda",
            "Modelo elegante e delicado",
            "Tecido liso ou leve, sem estampas",
            "Acessórios são bem-vindos",
          ],
        },
      ],
      orientacoes: ORIENTACOES_GERAIS,
    };
  }

  if (categoria === "amigo-noivo") {
    return {
      apresentacao:
        "Você faz parte da história do noivo e terá uma presença especial ao lado dele durante a preparação e a celebração.",
      traje: [
        {
          titulo: "Traje do amigo do noivo",
          itens: [
            "Terno preto",
            "Camisa branca",
            "Gravata lavanda",
            "Sapato social clássico",
            "Colete opcional",
          ],
        },
      ],
      orientacoes: ORIENTACOES_GERAIS,
    };
  }

  return {
    apresentacao: `Sua participação como ${funcao.toLowerCase()} é muito importante para nós. A assessoria informará a formação, a entrada e os demais detalhes da cerimônia.`,
    traje: [],
    orientacoes: ORIENTACOES_GERAIS,
  };
}

function CartaoFuncao({
  convidado,
  contexto,
}: {
  convidado: ConvidadoComFuncao;
  contexto: "propria" | "crianca";
}) {
  const detalhes = detalhesDaFuncao(convidado);
  return (
    <article className="function-card">
      <p className="function-owner">
        {contexto === "propria" ? "Sua função" : `Função de ${convidado.nome}`}
      </p>
      <h3>{convidado.funcao}</h3>
      <p>{detalhes.apresentacao}</p>
      {detalhes.traje.length > 0 && (
        <div className="function-attire-grid">
          {detalhes.traje.map((grupo) => (
            <section key={grupo.titulo}>
              <h4>{grupo.titulo}</h4>
              <ul>
                {grupo.itens.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
      <section className="function-day-notes">
        <h4>No grande dia</h4>
        <ul>
          {detalhes.orientacoes.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </section>
    </article>
  );
}

export function ManualFuncao({ acesso }: { acesso: AcessoFuncoes }) {
  return (
    <div className="panel function-panel">
      <p className="eyebrow">Sua participação no grande dia</p>
      <h1>{fraseMeuPapel(acesso)}</h1>
      <p className="function-intro">
        Aqui estão somente as informações relacionadas à sua função e, quando
        aplicável, às crianças do cortejo pelas quais você é responsável.
      </p>

      {acesso.funcaoPropria && (
        <section className="function-section">
          <h2>Informações da sua função</h2>
          <CartaoFuncao convidado={acesso.funcaoPropria} contexto="propria" />
        </section>
      )}

      {acesso.responsavelPorCrianca && (
        <section className="function-section child-responsibility">
          <span className="function-badge">Responsável por criança do cortejo</span>
          <h2>Informações das crianças sob sua responsabilidade</h2>
          <p>
            Você poderá acompanhar as orientações e baixar o manual das crianças
            vinculadas ao seu grupo. Cada criança também verá estas informações
            ao acessar o próprio perfil.
          </p>
          <div className="child-function-list">
            {acesso.criancasGerenciadas.map((crianca) => (
              <CartaoFuncao
                key={crianca.id}
                convidado={crianca}
                contexto="crianca"
              />
            ))}
          </div>
        </section>
      )}

      {acesso.manuais.length > 0 && (
        <section className="function-downloads">
          <p className="eyebrow">Materiais para guardar</p>
          <h2>Baixar seus manuais</h2>
          <p>
            Os botões abaixo exibem apenas os manuais associados a você e às
            crianças do cortejo pelas quais você é responsável.
          </p>
          <div>
            {acesso.manuais.map((codigo) => {
              const manual = ARQUIVOS_MANUAIS[codigo];
              return (
                <a
                  className="primary manual-download"
                  href={manual.arquivo}
                  download
                  key={codigo}
                >
                  <span aria-hidden="true">↓</span>
                  Baixar {manual.titulo} (PDF)
                </a>
              );
            })}
          </div>
        </section>
      )}
    </div>
  );
}
