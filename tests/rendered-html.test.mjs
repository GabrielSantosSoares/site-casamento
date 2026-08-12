import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("declares production metadata and the public guest entry", async () => {
  const [layout, site] = await Promise.all([
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../componentes/SiteCasamento.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(layout, /<html lang="pt-BR">/);
  assert.match(layout, /Gabriel & Alanna \| 03\.10\.2026/);
  assert.match(layout, /monograma-ga\.png/);
  assert.match(site, /Área do convidado/);
  assert.doesNotMatch(layout + site, /codex-preview|\/workspace\/sites\//i);
});

test("keeps public event information private without database credentials", async () => {
  const [page, api] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(page, /cidade: "Candeias-BA"/);
  assert.match(page, /nome_espaco: ""/);
  assert.match(page, /endereco: ""/);
  assert.match(api, /local_liberado:false/);
  assert.match(api, /nome_espaco:""/);
  assert.match(api, /endereco:""/);
});

test("accepts the legacy six-digit organization password format", async () => {
  const [api, adminPage] = await Promise.all([
    readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/x/page.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(api, /if\(!data\.senha\)return/);
  assert.match(api, /verificarHashSenha\(data\.senha/);
  assert.match(adminPage, /minLength=\{primeiro \? 8 : 6\}/);
});

test("keeps login, organization codes, and guest-list layout regressions covered", async () => {
  const [adminPage, dashboard, styles, migration] = await Promise.all([
    readFile(new URL("../app/x/page.tsx", import.meta.url), "utf8"),
    readFile(
      new URL("../componentes/DashboardNoivos.tsx", import.meta.url),
      "utf8",
    ),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(
      new URL(
        "../supabase/migration_034_codigos_organizacao_login.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  ]);

  assert.match(adminPage, /Usuário ou código/);
  assert.match(adminPage, /minLength=\{primeiro \? 8 : 6\}/);
  assert.match(dashboard, /Código de acesso/);
  assert.match(dashboard, /codigo: orgCodigo \|\| null/);
  assert.match(styles, /\.guest-admin-table \.table-row/);
  assert.match(styles, /content: "Pessoa"/);
  assert.match(migration, /codigo_indisponivel/);
  assert.match(migration, /codigo=v_codigo/);
});

test("keeps group management integrated with guest creation", async () => {
  const [dashboard, styles, migration, completeSql] = await Promise.all([
    readFile(new URL("../componentes/DashboardNoivos.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migration_035_grupos_integrados_convidados.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Grupos de convidados/);
  assert.match(dashboard, /Pesquise pelo nome ou código do grupo/);
  assert.match(dashboard, /normalizar\(`\$\{grupo\.codigo\} \$\{grupo\.titulo\}`\)/);
  assert.match(dashboard, /codigo: grupo \|\| undefined/);
  assert.doesNotMatch(dashboard, /setPagina\("grupos"\)/);
  assert.match(styles, /\.group-combobox-options/);
  assert.match(styles, /\.group-management-form/);
  assert.match(migration, /v_codigo_grupo/);
  assert.match(migration, /max\(ordem\)\+1/);
  assert.match(completeSql, /migration_035_grupos_integrados_convidados\.sql/);
});

test("keeps import templates, gift duplicate review, and manual gift management", async () => {
  const [dashboard, api, styles, migration, completeSql] = await Promise.all([
    readFile(new URL("../componentes/DashboardNoivos.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(
      new URL(
        "../supabase/migration_036_modelos_duplicidades_gestao_presentes.sql",
        import.meta.url,
      ),
      "utf8",
    ),
    readFile(
      new URL("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql", import.meta.url),
      "utf8",
    ),
  ]);

  assert.match(dashboard, /modelo-importacao-convidados\.xlsx/);
  assert.match(dashboard, /modelo-importacao-presentes\.xlsx/);
  assert.match(dashboard, /Presentes com nomes idênticos/);
  assert.match(dashboard, /Adicionar presente/);
  assert.match(dashboard, /Apagar presente/);
  assert.match(api, /action===\"administrar_presente\"/);
  assert.match(api, /permitir_duplicado:item\.permitir_duplicado===true/);
  assert.match(styles, /\.gift-create-form/);
  assert.match(styles, /\.gift-admin-actions/);
  assert.match(migration, /administrar_presente_dashboard/);
  assert.match(migration, /set ativo=false/);
  assert.match(migration, /v_permitir_duplicado/);
  assert.ok(
    completeSql.indexOf("migration_036_modelos_duplicidades_gestao_presentes.sql") >
      completeSql.indexOf("migration_035_grupos_integrados_convidados.sql"),
  );
});

test("keeps gift editing, unlimited quantities, donations, deliveries, and donor codes", async () => {
  const [dashboard, gifts, inviteApi, paymentsApi, styles, migration, completeSql] =
    await Promise.all([
      readFile(new URL("../componentes/DashboardNoivos.tsx", import.meta.url), "utf8"),
      readFile(new URL("../componentes/ListaPresentes.tsx", import.meta.url), "utf8"),
      readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
      readFile(new URL("../app/api/mercado-pago/route.ts", import.meta.url), "utf8"),
      readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
      readFile(
        new URL(
          "../supabase/migration_037_edicao_presentes_entregas_ilimitados.sql",
          import.meta.url,
        ),
        "utf8",
      ),
      readFile(
        new URL("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql", import.meta.url),
        "utf8",
      ),
    ]);

  assert.match(dashboard, /Editar presente/);
  assert.match(dashboard, /Deixe vazio para permitir assinaturas sem limite/);
  assert.match(dashboard, /Confirmar entrega/);
  assert.match(dashboard, /Código: \{p\.codigo_presenteador/);
  assert.match(gifts, /O item não será comprado pelo Mercado Pago/);
  assert.match(gifts, /quantidade_total === null/);
  assert.match(inviteApi, /action==="administrar_entrega_presente"/);
  assert.match(inviteApi, /data\.acao==="criar"\|\|data\.acao==="editar"/);
  assert.match(paymentsApi, /codigo_presenteador/);
  assert.match(styles, /\.delivery-badge\.delivered/);
  assert.match(migration, /quantidade_total is null/);
  assert.match(migration, /entregue_em timestamptz/);
  assert.match(migration, /administrar_entrega_presente/);
  assert.ok(
    completeSql.indexOf("migration_037_edicao_presentes_entregas_ilimitados.sql") >
      completeSql.indexOf("migration_036_modelos_duplicidades_gestao_presentes.sql"),
  );
});
