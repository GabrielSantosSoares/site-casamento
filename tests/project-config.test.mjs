import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("uses the native Next.js build expected by Vercel", async () => {
  const pkg = JSON.parse(await read("package.json"));
  const tsconfig = JSON.parse(await read("tsconfig.json"));
  const vercel = JSON.parse(await read("vercel.json"));

  assert.equal(pkg.engines.node, "22.x");
  assert.equal(pkg.scripts.build, "next build --webpack");
  assert.equal(pkg.scripts.dev, "next dev");
  assert.equal(pkg.scripts.start, "next start");
  assert.equal(pkg.devDependencies.vinext, undefined);
  assert.equal(pkg.devDependencies.vite, undefined);
  assert.ok(tsconfig.exclude.includes("vite.config.ts"));
  assert.ok(tsconfig.exclude.includes("worker"));
  assert.ok(tsconfig.exclude.includes("scripts"));
  assert.deepEqual(vercel, {});
});

test("keeps the complete database installer in dependency order", async () => {
  const sql = await read("supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql");
  const createsIndividualCode = sql.indexOf(
    "add column if not exists codigo_individual varchar(6)",
  );
  const firstCodeLookup = sql.indexOf("where codigo_individual = v_codigo");

  assert.ok(createsIndividualCode >= 0);
  assert.ok(firstCodeLookup > createsIndividualCode);
  assert.match(sql, /migration_033_revisao_geral_perfis_notificacoes\.sql/);
  assert.match(sql, /cron\.schedule\(/);
  assert.match(sql, /expirar_reservas_pagamento\(\)/);
});
