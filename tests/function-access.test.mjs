import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";

async function carregarFuncoes() {
  const fonte = await readFile(
    new URL("../lib/funcoes.ts", import.meta.url),
    "utf8",
  );
  const javascript = ts.transpileModule(fonte, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
    },
  }).outputText;
  return import(
    `data:text/javascript;base64,${Buffer.from(javascript).toString("base64")}`
  );
}

const pessoas = [
  {
    id: "adulto-gestor",
    nome: "Pessoa gestora",
    codigo_individual: "GEST01",
    pode_gerenciar: true,
    funcao: "Madrinha",
    crianca: false,
  },
  {
    id: "adulto-convidado",
    nome: "Outro adulto",
    codigo_individual: "ADUL02",
    pode_gerenciar: false,
    funcao: "Amigo do Noivo",
    crianca: false,
  },
  {
    id: "crianca-1",
    nome: "Criança do cortejo",
    codigo_individual: "CRIA01",
    pode_gerenciar: false,
    funcao: "Porta-aliança",
    crianca: true,
  },
  {
    id: "crianca-2",
    nome: "Outra criança",
    codigo_individual: "CRIA02",
    pode_gerenciar: false,
    funcao: null,
    crianca: true,
  },
];

test("cada adulto comum vê somente a própria função", async () => {
  const { resolverAcessoFuncoes } = await carregarFuncoes();
  const acesso = resolverAcessoFuncoes("ADUL02", pessoas);

  assert.equal(acesso.funcaoPropria?.id, "adulto-convidado");
  assert.deepEqual(acesso.criancasGerenciadas, []);
  assert.deepEqual(acesso.manuais, ["amigos-do-noivo"]);
});

test("gestor vê sua função primeiro e depois as crianças do cortejo", async () => {
  const { fraseMeuPapel, resolverAcessoFuncoes } = await carregarFuncoes();
  const acesso = resolverAcessoFuncoes("GEST01", pessoas);

  assert.equal(acesso.funcaoPropria?.id, "adulto-gestor");
  assert.deepEqual(
    acesso.criancasGerenciadas.map((pessoa) => pessoa.id),
    ["crianca-1"],
  );
  assert.deepEqual(acesso.manuais, ["padrinhos", "criancas"]);
  assert.match(fraseMeuPapel(acesso), /responsável por criança do cortejo/i);
});

test("criança vê apenas a própria função e o próprio manual", async () => {
  const { resolverAcessoFuncoes } = await carregarFuncoes();
  const acesso = resolverAcessoFuncoes("CRIA01", pessoas);

  assert.equal(acesso.funcaoPropria?.id, "crianca-1");
  assert.equal(acesso.responsavelPorCrianca, false);
  assert.deepEqual(acesso.criancasGerenciadas, []);
  assert.deepEqual(acesso.manuais, ["criancas"]);
});

test("código geral do grupo não expõe funções pessoais", async () => {
  const { resolverAcessoFuncoes } = await carregarFuncoes();
  const acesso = resolverAcessoFuncoes("GRUP01", pessoas);

  assert.equal(acesso.pessoa, null);
  assert.equal(acesso.temFuncao, false);
  assert.deepEqual(acesso.manuais, []);
});

test("mantém proteção na API, migração final e os quatro PDFs", async () => {
  const [api, migration, completeSql, component, ...pdfStats] = await Promise.all([
    readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
    readFile(
      new URL(
        "../supabase/migration_038_funcoes_individuais_manuais_criancas.sql",
        import.meta.url,
      ),
      "utf8",
    ),
    readFile(
      new URL("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql", import.meta.url),
      "utf8",
    ),
    readFile(new URL("../componentes/ManualFuncao.tsx", import.meta.url), "utf8"),
    stat(new URL("../public/manuais/manual-dos-padrinhos.pdf", import.meta.url)),
    stat(new URL("../public/manuais/manual-das-demoiselles.pdf", import.meta.url)),
    stat(new URL("../public/manuais/manual-do-amigo-do-noivo.pdf", import.meta.url)),
    stat(new URL("../public/manuais/manual-das-criancas.pdf", import.meta.url)),
  ]);

  assert.match(api, /sanitizarFuncoesDoConvite/);
  assert.match(api, /idsComFuncaoLiberada/);
  assert.match(migration, /v_pode_gerenciar_criancas/);
  assert.match(migration, /'funcao', null/);
  assert.ok(
    completeSql.indexOf("migration_038_funcoes_individuais_manuais_criancas.sql") >
      completeSql.indexOf("migration_037_edicao_presentes_entregas_ilimitados.sql"),
  );
  assert.match(component, /Responsável por criança do cortejo/);
  assert.match(component, /Baixar \{manual\.titulo\} \(PDF\)/);
  pdfStats.forEach((arquivo) => assert.ok(arquivo.size > 100_000));
});
