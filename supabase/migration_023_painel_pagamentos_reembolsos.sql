begin;

alter table public.reservas_presentes
  add column if not exists pagador_nome text,
  add column if not exists pagador_email text,
  add column if not exists meio_pagamento_detalhe text,
  add column if not exists valor_transacao numeric(12,2),
  add column if not exists reembolso_id text,
  add column if not exists reembolsado_em timestamptz;

alter table public.reservas_presentes
  drop constraint if exists reservas_presentes_status_check;

alter table public.reservas_presentes
  add constraint reservas_presentes_status_check
  check (status in ('pendente','confirmado','cancelado','rejeitado','reembolsado'));

create index if not exists reservas_pagamentos_admin_idx
  on public.reservas_presentes (meio, criado_em desc)
  where meio = 'mercado_pago';

notify pgrst, 'reload schema';
commit;
