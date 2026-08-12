import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("preserves the invitation after Mercado Pago and routes single-person groups", async () => {
  const page = await readFile(
    new URL("../componentes/SiteCasamento.tsx", import.meta.url),
    "utf8",
  );

  assert.match(page, /retornoPagamentoAtual/);
  assert.match(page, /setView\("presentes"\)/);
  assert.match(page, /casamento_codigo_ativo/);
  assert.match(page, /sessionStorage\.setItem/);
  assert.match(page, /found\.convidados\.length === 1/);
  assert.match(page, /window\.location\.replace\(\s*`\/c\/\$\{codigoIndividualUnico\}/);
  assert.match(page, /payment-return-status/);
});

test("sends a useful item description and keeps the payment list compatible", async () => {
  const [api, dashboard] = await Promise.all([
    readFile(new URL("../app/api/mercado-pago/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../componentes/DashboardNoivos.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(api, /description: `Doação aos noivos/);
  assert.match(api, /metadata: \{ codigo_convidado: codigo \}/);
  assert.match(api, /modoCompatibilidade/);
  assert.match(api, /select=\$\{camposBase\},codigo_doador/);
  assert.match(api, /select=\$\{camposBase\}&order/);
  assert.match(api, /codigo_presenteador: r\.codigo_doador \|\| r\.convites\?\.codigo/);
  assert.match(dashboard, /if \(d\.aviso\) setAviso\(d\.aviso\)/);
});

test("only acknowledges a webhook after a real database update", async () => {
  const webhook = await readFile(
    new URL("../app/api/mercado-pago/webhook/route.ts", import.meta.url),
    "utf8",
  );

  assert.match(webhook, /Prefer: "return=representation"/);
  assert.match(webhook, /atualizados\.length === 0/);
  assert.match(webhook, /status: 404/);
  assert.match(webhook, /status: 502/);
  assert.match(webhook, /status: 500/);
  assert.match(webhook, /atualizados: atualizados\.length/);
});

test("keeps migration 040 idempotent and after the previous migrations", async () => {
  const [migration, completeSql] = await Promise.all([
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

  assert.match(migration, /add column if not exists codigo_doador/);
  assert.match(migration, /create index if not exists reservas_presentes_codigo_doador_idx/);
  assert.match(migration, /set codigo_doador = c\.codigo/);
  assert.match(migration, /notify pgrst, 'reload schema'/);
  assert.ok(
    completeSql.indexOf("migration_040_retorno_pagamentos_convites_unitarios.sql") >
      completeSql.indexOf("migration_039_responsaveis_criancas_trajes.sql"),
  );
  assert.ok(
    completeSql.indexOf("migration_042_pais_convites_grupos_controle_entrada.sql") >
      completeSql.indexOf("migration_040_retorno_pagamentos_convites_unitarios.sql"),
  );
});
