-- Execute este arquivo uma única vez no SQL Editor do Supabase.
create extension if not exists pgcrypto;

create table if not exists public.convites (
  id uuid primary key default gen_random_uuid(),
  codigo varchar(6) not null unique check (codigo = upper(codigo) and codigo ~ '^[A-Z0-9]{6}$'),
  nome_familia text not null,
  funcao_cortejo text,
  instrucoes_cortejo jsonb not null default '[]'::jsonb,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.convidados (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  nome text not null,
  principal boolean not null default false,
  ordem smallint not null default 0,
  criado_em timestamptz not null default now()
);

create table if not exists public.confirmacoes (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  convidado_id uuid not null references public.convidados(id) on delete cascade,
  status text not null check (status in ('sim', 'nao')),
  mensagem text,
  atualizado_em timestamptz not null default now(),
  unique (convite_id, convidado_id)
);

create index if not exists convidados_convite_idx on public.convidados (convite_id, ordem);
create index if not exists confirmacoes_convite_idx on public.confirmacoes (convite_id);

alter table public.convites enable row level security;
alter table public.convidados enable row level security;
alter table public.confirmacoes enable row level security;
revoke all on public.convites from anon, authenticated;
revoke all on public.convidados from anon, authenticated;
revoke all on public.confirmacoes from anon, authenticated;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_convite public.convites%rowtype;
begin
  select * into v_convite from public.convites
   where codigo = upper(trim(p_codigo)) and ativo = true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo', v_convite.codigo,
    'nome_familia', v_convite.nome_familia,
    'funcao_cortejo', v_convite.funcao_cortejo,
    'instrucoes_cortejo', v_convite.instrucoes_cortejo,
    'convidados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id, 'nome', g.nome, 'principal', g.principal, 'status', c.status
      ) order by g.ordem, g.nome)
      from public.convidados g
      left join public.confirmacoes c on c.convidado_id = g.id and c.convite_id = v_convite.id
      where g.convite_id = v_convite.id
    ), '[]'::jsonb)
  );
end; $$;

create or replace function public.salvar_confirmacao(
  p_codigo text, p_respostas jsonb, p_mensagem text default null
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_convite_id uuid; v_item jsonb; v_convidado_id uuid; v_status text;
begin
  select id into v_convite_id from public.convites
   where codigo = upper(trim(p_codigo)) and ativo = true;
  if v_convite_id is null or jsonb_typeof(p_respostas) <> 'array' then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_convidado_id := (v_item->>'convidado_id')::uuid;
    v_status := v_item->>'status';
    if v_status not in ('sim', 'nao') then raise exception 'Status inválido'; end if;
    if not exists (select 1 from public.convidados where id = v_convidado_id and convite_id = v_convite_id)
      then raise exception 'Convidado inválido'; end if;
    insert into public.confirmacoes (convite_id, convidado_id, status, mensagem, atualizado_em)
    values (v_convite_id, v_convidado_id, v_status, nullif(trim(p_mensagem), ''), now())
    on conflict (convite_id, convidado_id) do update set
      status = excluded.status, mensagem = excluded.mensagem, atualizado_em = now();
  end loop;
  return true;
end; $$;

revoke all on function public.buscar_convite(text) from public;
revoke all on function public.salvar_confirmacao(text, jsonb, text) from public;
grant execute on function public.buscar_convite(text) to anon, authenticated;
grant execute on function public.salvar_confirmacao(text, jsonb, text) to anon, authenticated;

insert into public.convites (codigo, nome_familia, funcao_cortejo, instrucoes_cortejo)
values ('GA2026', 'Família Soares', 'Padrinhos', '[
  {"icone":"◷","titulo":"Chegada","texto":"Às 18h30, 30 minutos antes da cerimônia."},
  {"icone":"♢","titulo":"Traje","texto":"Terno cinza e gravata azul serenity."},
  {"icone":"⌖","titulo":"Encontro","texto":"Apresente-se à assessoria ao chegar."}
]'::jsonb)
on conflict (codigo) do update set nome_familia=excluded.nome_familia,
  funcao_cortejo=excluded.funcao_cortejo, instrucoes_cortejo=excluded.instrucoes_cortejo,
  ativo=true, atualizado_em=now();

insert into public.convidados (convite_id, nome, principal, ordem)
select c.id, d.nome, d.principal, d.ordem from public.convites c
cross join (values ('Gabriel Soares', true, 1), ('Acompanhante', false, 2)) d(nome, principal, ordem)
where c.codigo='GA2026' and not exists (
  select 1 from public.convidados g where g.convite_id=c.id and g.nome=d.nome
);
