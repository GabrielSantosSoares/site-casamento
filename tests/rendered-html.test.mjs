import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("renders the public wedding page with production metadata", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  const response = await worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );

  assert.equal(response.status, 200);
  assert.match(
    response.headers.get("content-type") ?? "",
    /^text\/html\b/i,
  );
  const html = await response.text();
  assert.match(html, /<html[^>]*\blang=["']pt-BR["']/i);
  assert.match(html, /<title>Gabriel &amp; Alanna \| 03\.10\.2026<\/title>/i);
  assert.match(html, /Área do convidado/i);
  assert.match(html, /monograma-ga\.png/i);
  assert.doesNotMatch(html, /codex-preview/i);
  assert.doesNotMatch(html, /\/workspace\/sites\//i);
});

test("keeps public event information available without database credentials", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("api-test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  const response = await worker.fetch(
    new Request("http://localhost/api/convite"),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    evento: {
      data: "2026-10-03",
      hora: "18:30",
      cidade: "Candeias-BA",
      local_liberado: false,
      nome_espaco: "Espaço Brunus",
      endereco: "Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000",
      link_maps: null,
    },
  });
});

test("accepts a legacy six-digit temporary password for organization login", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("login-test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  const response = await worker.fetch(
    new Request("http://localhost/api/convite", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        action: "login_conta",
        codigo: "ABC123",
        senha: "123456",
      }),
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );

  assert.notEqual(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: "Serviço seguro indisponível.",
  });
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

test("keeps payment return, webhook reconciliation, and single-person invitations", async () => {
  const [
    page,
    inviteApi,
    paymentsApi,
    webhook,
    exportsComponent,
    styles,
    migration,
    completeSql,
  ] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/convite/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/mercado-pago/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/mercado-pago/webhook/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../componentes/ExportarConvites.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(
      new URL(
        "../supabase/migration_040_retorno_pagamentos_convites_unitarios.sql",
        import.meta.url,
      ),
      "utf8",
    ),
    readFile(
      new URL("../supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql", import.meta.url),
      "utf8",
    ),
  ]);

  assert.match(paymentsApi, /description: `Doação do valor referente ao presente/);
  assert.match(paymentsApi, /possuiCodigoDoador = false/);
  assert.match(paymentsApi, /presentes\?select=id,nome/);
  assert.match(webhook, /searchParams\.get\("data\.id"\)/);
  assert.match(webhook, /Prefer: "return=representation"/);
  assert.match(webhook, /registros\.length === 0/);
  assert.match(inviteApi, /resolverConviteUnitario/);
  assert.match(inviteApi, /codigo_individual_destino/);
  assert.match(inviteApi, /sameSite:"lax"/);
  assert.match(page, /payment-return-banner/);
  assert.match(page, /window\.history\.replaceState\(\{\}, "", `\/c\/\$\{codigoEfetivo\}`\)/);
  assert.match(exportsComponent, /\? `\$\{base\}\/c\/\$\{pessoaUnica\.codigo_individual\}`/);
  assert.match(styles, /\.payment-return-banner\.sucesso/);
  assert.match(migration, /codigo_doador/);
  assert.match(migration, /v_codigo text := upper\(trim\(p_codigo\)\)/);
  assert.ok(
    completeSql.indexOf("migration_040_retorno_pagamentos_convites_unitarios.sql") >
      completeSql.indexOf("migration_039_responsaveis_criancas_trajes.sql"),
  );
});
