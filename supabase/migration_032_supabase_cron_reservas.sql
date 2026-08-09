-- Transfere a expiração automática das reservas do Vercel Cron para o Supabase Cron.
-- Execute após a migration 030 no banco atual.

begin;

create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'expirar-reservas-pagamento',
  '*/5 * * * *',
  $cron$select public.expirar_reservas_pagamento();$cron$
);

commit;
