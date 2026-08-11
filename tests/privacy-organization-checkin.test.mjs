import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const ler = (caminho) =>
  readFile(new URL(`../${caminho}`, import.meta.url), "utf8");

test("server-renders public event data without leaking the venue", async () => {
  const [page, loader, app, api] = await Promise.all([
    ler("app/page.tsx"),
    ler("lib/dados-iniciais.ts"),
    ler("componentes/AplicacaoCasamento.tsx"),
    ler("app/api/convite/route.ts"),
  ]);

  assert.match(page, /export const dynamic = "force-dynamic"/);
  assert.match(page, /await carregarEventoPublicoInicial\(\)/);
  assert.match(loader, /\/rest\/v1\/rpc\/\$\{nome\}/);
  assert.match(loader, /local_liberado: false/);
  assert.match(loader, /nome_espaco: ""/);
  assert.match(loader, /endereco: ""/);
  assert.match(api, /rpc\("evento_publico"/);

  const cartaoPublico = app.slice(
    app.indexOf('<div className="detail-card">'),
    app.indexOf('<section className="access"'),
  );
  assert.match(cartaoPublico, /Cerimônia às \{dataEvento\.hora\}/);
  assert.match(cartaoPublico, /eventoAtual\.cidade/);
  assert.doesNotMatch(cartaoPublico, /endereco|nome_espaco|Aguardando a liberação/i);
  assert.match(app, /className="quick-event-info"/);
  assert.match(app, /invitation\.evento\.endereco/);
});

test("keeps the gift and election notices and accessible RSVP choices", async () => {
  const [app, gifts, styles, api] = await Promise.all([
    ler("componentes/AplicacaoCasamento.tsx"),
    ler("componentes/ListaPresentes.tsx"),
    ler("app/globals.css"),
    ler("app/api/convite/route.ts"),
  ]);

  assert.match(gifts, /Antes de escolher/);
  assert.match(gifts, /Inicialmente tínhamos planejados não fazer uma lista/);
  assert.match(gifts, /Sintam-se totalmente livres - a presença e o afeto/);
  assert.match(app, /Um pedido especial/);
  assert.match(app, /className="election-highlight"/);
  assert.match(app, /na véspera das eleições/);
  assert.match(app, /Li e entendi/);
  assert.match(app, /aviso_eleicoes_lido/);
  assert.match(api, /confirmar_leitura_aviso_eleicoes/);
  assert.match(app, /Gerenciar presença/);

  const confirmacao = app.slice(
    app.indexOf('{view === "presenca"'),
    app.indexOf('{view === "presentes"'),
  );
  assert.match(confirmacao, /Estarei presente/);
  assert.match(confirmacao, /Não poderei ir/);
  assert.match(confirmacao, /aria-pressed/);
  assert.doesNotMatch(confirmacao, /<select/);
  assert.match(styles, /\.attendance-choice/);
  assert.match(styles, /\.election-highlight/);
});

test("provides procession, organization roles, deletion, parents and check-in", async () => {
  const [dashboard, checkin, checkinPage, api, migration] = await Promise.all([
    ler("componentes/DashboardNoivos.tsx"),
    ler("componentes/ControleEntrada.tsx"),
    ler("app/lista/page.tsx"),
    ler("app/api/convite/route.ts"),
    ler("supabase/migration_041_privacidade_local_cortejo_organizacao_checkin.sql"),
  ]);

  assert.match(dashboard, /Visão do cortejo/);
  assert.match(dashboard, /Presença confirmada/);
  for (const role of ["Fotógrafo", "Film maker", "Filmagem", "Apoio"])
    assert.match(dashboard, new RegExp(role));
  assert.match(dashboard, /Escolha ou digite uma nova função/);
  assert.match(dashboard, /administrarOrganizacao\("excluir"/);
  assert.match(dashboard, /href="\/lista"/);
  assert.match(checkinPage, /ControleEntrada/);
  assert.match(checkin, /PRESENÇA CONFIRMADA/);
  assert.match(checkin, /Confirmar chegada/);
  assert.match(checkin, /Faltantes confirmados/);
  assert.match(api, /listar_controle_acesso/);
  assert.match(api, /confirmar_chegada_evento/);
  assert.match(migration, /'pai do noivo', 'mae do noivo'/);
  assert.match(migration, /then 'assessoria'/);
  assert.match(migration, /p_acao = 'excluir'/);
  assert.match(migration, /not in \('admin', 'noivos'\)/);
});

test("keeps migration 041 complete, ordered and identical in the fresh install SQL", async () => {
  const [migration, completeSql] = await Promise.all([
    ler("supabase/migration_041_privacidade_local_cortejo_organizacao_checkin.sql"),
    ler("supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql"),
  ]);
  const marker =
    "-- Privacidade do local, aviso de confirmação, funções livres da organização,";
  const embedded = completeSql.slice(completeSql.lastIndexOf(marker));

  assert.equal(embedded, migration);
  assert.equal((migration.match(/\$\$/g) ?? []).length % 2, 0);
  assert.match(migration, /^begin;/m);
  assert.match(migration, /commit;\s*$/);
  assert.match(migration, /create or replace function public\.evento_publico\(\)/);
  assert.match(migration, /create or replace function public\.evento_interno\(\)/);
  assert.match(migration, /rename to buscar_convite_040/);
  assert.match(migration, /rename to dashboard_noivos_040/);
  assert.match(migration, /notify pgrst, 'reload schema'/);
  assert.ok(
    completeSql.indexOf("migration_041_privacidade_local_cortejo_organizacao_checkin.sql") >
      completeSql.indexOf("migration_040_retorno_pagamentos_convites_unitarios.sql"),
  );
});
