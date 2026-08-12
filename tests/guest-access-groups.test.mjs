import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const ler = (caminho) => readFile(new URL(caminho, import.meta.url), "utf8");

test("prioritizes individual invitations, including one-person groups", async () => {
  const [api, site] = await Promise.all([
    ler("../app/api/convite/route.ts"),
    ler("../componentes/SiteCasamento.tsx"),
  ]);

  assert.match(api, /const convidadoDoCodigo = convidadosCompletos\.find/);
  assert.match(api, /convites\?codigo=eq\./);
  assert.match(api, /const codigoIndividualPadrao/);
  assert.match(api, /codigo === codigoConjunto[^]*convidadoUnico/);
  assert.match(api, /redirecionar_codigo_individual:conviteIndividual\?codigoIndividualPadrao:null/);
  assert.match(site, /data\.convite_individual === true/);
  assert.match(site, /window\.location\.replace\(\s*`\/c\/\$\{redirecionarCodigo\}/);
  assert.match(site, /const acessoPeloGrupo =\s*!conviteIndividual/);
});

test("gives parents the intended guest and organization management profile", async () => {
  const [dashboard, api, migration] = await Promise.all([
    ler("../componentes/DashboardNoivos.tsx"),
    ler("../app/api/convite/route.ts"),
    ler("../supabase/migration_042_pais_convites_grupos_controle_entrada.sql"),
  ]);

  assert.match(dashboard, /const perfilPais = \[/);
  assert.match(dashboard, /"pai do noivo"/);
  assert.match(dashboard, /"mae da noiva"/);
  assert.match(dashboard, /const podeAdministrarConvidados = !assessoria \|\| perfilPais/);
  assert.match(dashboard, /Área da Organização/);
  assert.match(api, /listar_organizacao_gestores/);
  assert.match(migration, /eh_administrador_convidados/);
  assert.match(migration, /'pai do noivo','mae do noivo','pai da noiva','mae da noiva'/);
  assert.match(migration, /administrar_convidado_com_codigo/);
  assert.match(migration, /remover_convidado_organizacao/);
  assert.match(migration, /administrar_organizacao_backend/);
});

test("separates guest and group management and supports changing membership", async () => {
  const [dashboard, migration, styles] = await Promise.all([
    ler("../componentes/DashboardNoivos.tsx"),
    ler("../supabase/migration_042_pais_convites_grupos_controle_entrada.sql"),
    ler("../app/globals.css"),
  ]);

  assert.match(dashboard, /Gerenciar convidados/);
  assert.match(dashboard, /Gerenciar grupos/);
  assert.match(dashboard, /grupoAbertoDados/);
  assert.match(dashboard, /pessoasDoGrupo/);
  assert.match(dashboard, /pessoasForaDoGrupo/);
  assert.match(dashboard, /associarPessoaAoGrupo/);
  assert.match(dashboard, /tornarConviteIndividual/);
  assert.match(migration, /p_acao='associar_pessoa'/);
  assert.match(migration, /p_acao='tornar_individual'/);
  assert.match(styles, /\.management-switch/);
  assert.match(styles, /\.group-detail/);
});

test("keeps the requested wording, attendance notice, and public privacy", async () => {
  const [gifts, site, page, api] = await Promise.all([
    ler("../componentes/ListaPresentes.tsx"),
    ler("../componentes/SiteCasamento.tsx"),
    ler("../app/page.tsx"),
    ler("../app/api/convite/route.ts"),
  ]);

  assert.match(gifts, /pedidos carinhosos de alguns amigos e familiares/);
  assert.doesNotMatch(gifts, /pedidos carinhos\b(?!os)/);
  assert.match(site, /Um pedido especial aos nossos convidados:/);
  assert.match(site, /na véspera das eleições/);
  assert.match(site, /Li e entendi/);
  assert.match(page, /export const dynamic = "force-dynamic"/);
  assert.match(page, /eventoInicial=\{await carregarEventoPublico\(\)\}/);
  assert.match(api, /nome_espaco:""/);
  assert.match(api, /endereco:""/);
});

test("includes entrance control and the complete ordered installer", async () => {
  const [entrance, migration, complete] = await Promise.all([
    ler("../app/lista/page.tsx"),
    ler("../supabase/migration_042_pais_convites_grupos_controle_entrada.sql"),
    ler("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql"),
  ]);

  assert.match(entrance, /PRESENÇA CONFIRMADA/);
  assert.match(entrance, /Confirmar chegada/);
  assert.match(migration, /buscar_controle_entrada/);
  assert.match(migration, /confirmar_chegada_convidado/);
  assert.match(migration, /controle_entrada_resumo/);
  assert.ok(
    complete.indexOf("migration_042_pais_convites_grupos_controle_entrada.sql") >
      complete.indexOf("migration_040_retorno_pagamentos_convites_unitarios.sql"),
  );
  assert.equal(
    complete.match(/migration_042_pais_convites_grupos_controle_entrada\.sql/g)?.length,
    1,
  );
});
