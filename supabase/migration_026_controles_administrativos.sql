begin;

create table if not exists public.auditoria_administrativa (
  id uuid primary key default gen_random_uuid(),
  ator text not null,
  perfil text not null,
  acao text not null,
  entidade text not null,
  detalhes jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);

create table if not exists public.falhas_webhook_pagamento (
  id uuid primary key default gen_random_uuid(),
  pagamento_id text,
  etapa text not null,
  mensagem text not null,
  resolvida boolean not null default false,
  criado_em timestamptz not null default now(),
  resolvida_em timestamptz
);

create index if not exists auditoria_administrativa_criado_idx
  on public.auditoria_administrativa (criado_em desc);
create index if not exists falhas_webhook_pendentes_idx
  on public.falhas_webhook_pagamento (resolvida, criado_em desc);

alter table public.auditoria_administrativa enable row level security;
alter table public.falhas_webhook_pagamento enable row level security;

comment on table public.auditoria_administrativa is
  'Histórico imutável das alterações realizadas por noivos e administradores.';
comment on table public.falhas_webhook_pagamento is
  'Alertas internos de falhas no processamento das notificações do Mercado Pago.';

create or replace function public.registrar_auditoria_tabela()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id text;
begin
  v_id := coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id','');
  insert into public.auditoria_administrativa(ator,perfil,acao,entidade,detalhes)
  values('Aplicação','sistema',lower(tg_op),tg_table_name,jsonb_build_object('id',v_id));
  return coalesce(new,old);
end $$;

do $$ declare v_tabela text;
begin
  foreach v_tabela in array array['convites','convidados','confirmacoes','presentes','reservas_presentes','categorias_presentes','configuracao_evento','configuracoes_convites','organizacao','integracoes_pagamento'] loop
    execute format('drop trigger if exists auditoria_alteracoes on public.%I',v_tabela);
    execute format('create trigger auditoria_alteracoes after insert or update or delete on public.%I for each row execute function public.registrar_auditoria_tabela()',v_tabela);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
