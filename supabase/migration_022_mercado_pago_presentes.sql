begin;

create table if not exists public.integracoes_pagamento (
  id smallint primary key default 1 check (id = 1),
  provedor text not null default 'mercado_pago',
  ambiente text not null default 'producao' check (ambiente in ('teste','producao')),
  public_key text,
  access_token_cifrado text,
  conta_id text,
  conta_email text,
  ativa boolean not null default false,
  verificada_em timestamptz,
  atualizado_em timestamptz not null default now()
);

insert into public.integracoes_pagamento(id) values (1) on conflict (id) do nothing;
alter table public.integracoes_pagamento enable row level security;
revoke all on public.integracoes_pagamento from anon, authenticated;

alter table public.reservas_presentes drop constraint if exists reservas_presentes_status_check;
alter table public.reservas_presentes add constraint reservas_presentes_status_check
  check (status in ('pendente','confirmado','cancelado','rejeitado'));
alter table public.reservas_presentes add column if not exists meio text not null default 'fisico'
  check (meio in ('fisico','mercado_pago'));
alter table public.reservas_presentes add column if not exists preferencia_id text;
alter table public.reservas_presentes add column if not exists pagamento_id text;
alter table public.reservas_presentes add column if not exists pagamento_status text;
alter table public.reservas_presentes add column if not exists external_reference text;
alter table public.reservas_presentes add column if not exists aprovado_em timestamptz;
create index if not exists reservas_preferencia_idx on public.reservas_presentes(preferencia_id);
drop index if exists public.reservas_pagamento_id_unique;
create index if not exists reservas_pagamento_id_idx on public.reservas_presentes(pagamento_id) where pagamento_id is not null;
create index if not exists reservas_external_reference_idx on public.reservas_presentes(external_reference);

create or replace function public.listar_historico_presentes(p_codigo text)
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'presente_id',r.presente_id,'presente',p.nome,'quantidade',r.quantidade,
    'meio',r.meio,'status',r.status,'pagamento_status',r.pagamento_status,
    'editavel',(r.meio='fisico' and r.status='confirmado'),
    'criado_em',r.criado_em,'aprovado_em',r.aprovado_em
  ) order by r.criado_em desc),'[]'::jsonb)
  from public.reservas_presentes r
  join public.presentes p on p.id=r.presente_id
  join public.convites c on c.id=r.convite_id
  where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(
      select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo))
    )
  ) and r.status<>'cancelado';
$$;

create or replace function public.registrar_presentes_fisicos(p_codigo text,p_itens jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_item jsonb; v_presente_id uuid; v_quantidade integer; v_usada integer;
begin
  select c.id into v_convite_id from public.convites c where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo)))
  ) limit 1;
  if v_convite_id is null or jsonb_typeof(p_itens)<>'array' or jsonb_array_length(p_itens)=0 then return false; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_presente_id=(v_item->>'presente_id')::uuid; v_quantidade=(v_item->>'quantidade')::integer;
    perform 1 from public.presentes where id=v_presente_id and ativo=true for update;
    if not found or v_quantidade<1 then return false; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada from public.reservas_presentes
      where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_usada+v_quantidade>(select quantidade_total from public.presentes where id=v_presente_id) then return false; end if;
    insert into public.reservas_presentes(convite_id,presente_id,quantidade,status,meio)
      values(v_convite_id,v_presente_id,v_quantidade,'confirmado','fisico');
  end loop;
  return true;
end; $$;

create or replace function public.alterar_presente_fisico(p_codigo text,p_reserva_id uuid,p_quantidade integer,p_cancelar boolean default false)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_reserva public.reservas_presentes%rowtype; v_usada integer; v_total integer;
begin
  select r.* into v_reserva from public.reservas_presentes r join public.convites c on c.id=r.convite_id
  where r.id=p_reserva_id and r.meio='fisico' and r.status='confirmado' and c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo)))
  ) for update of r;
  if not found then return false; end if;
  if p_cancelar then update public.reservas_presentes set status='cancelado',atualizado_em=now() where id=p_reserva_id; return true; end if;
  if p_quantidade<1 then return false; end if;
  select quantidade_total into v_total from public.presentes where id=v_reserva.presente_id for update;
  select coalesce(sum(quantidade),0)::integer into v_usada from public.reservas_presentes
    where presente_id=v_reserva.presente_id and status in ('pendente','confirmado') and id<>p_reserva_id;
  if v_usada+p_quantidade>v_total then return false; end if;
  update public.reservas_presentes set quantidade=p_quantidade,atualizado_em=now() where id=p_reserva_id;
  return true;
end; $$;

revoke all on function public.listar_historico_presentes(text) from public;
revoke all on function public.registrar_presentes_fisicos(text,jsonb) from public;
revoke all on function public.alterar_presente_fisico(text,uuid,integer,boolean) from public;
grant execute on function public.listar_historico_presentes(text) to anon,authenticated;
grant execute on function public.registrar_presentes_fisicos(text,jsonb) to anon,authenticated;
grant execute on function public.alterar_presente_fisico(text,uuid,integer,boolean) to anon,authenticated;

notify pgrst,'reload schema';
commit;
