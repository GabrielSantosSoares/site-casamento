-- Migração 002: carrinho de presentes, manuais e Área dos Noivos
create extension if not exists pgcrypto;

alter table public.convites add column if not exists nivel_acesso smallint not null default 1
  check (nivel_acesso between 0 and 4);
alter table public.convites add column if not exists manuais text[] not null default '{}';
alter table public.convites add column if not exists senha_hash text;

create table if not exists public.presentes (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  descricao text,
  preco_centavos integer not null default 0 check (preco_centavos >= 0),
  quantidade_total integer not null default 1 check (quantidade_total > 0),
  ativo boolean not null default true,
  ordem smallint not null default 0,
  criado_em timestamptz not null default now()
);

create table if not exists public.reservas_presentes (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  presente_id uuid not null references public.presentes(id) on delete cascade,
  quantidade integer not null check (quantidade > 0),
  status text not null default 'confirmado' check (status in ('confirmado','cancelado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.sessoes_noivos (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  token_hash text not null unique,
  expira_em timestamptz not null,
  criado_em timestamptz not null default now()
);

create index if not exists reservas_presente_idx on public.reservas_presentes (presente_id,status);
create index if not exists reservas_convite_idx on public.reservas_presentes (convite_id,status);
create index if not exists sessoes_noivos_token_idx on public.sessoes_noivos (token_hash,expira_em);

alter table public.presentes enable row level security;
alter table public.reservas_presentes enable row level security;
alter table public.sessoes_noivos enable row level security;
revoke all on public.presentes from anon,authenticated;
revoke all on public.reservas_presentes from anon,authenticated;
revoke all on public.sessoes_noivos from anon,authenticated;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype;
begin
  select * into v_convite from public.convites
  where codigo=upper(trim(p_codigo)) and ativo=true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',v_convite.codigo,
    'nome_familia',v_convite.nome_familia,
    'funcao_cortejo',v_convite.funcao_cortejo,
    'instrucoes_cortejo',v_convite.instrucoes_cortejo,
    'nivel_acesso',v_convite.nivel_acesso,
    'manuais',v_convite.manuais,
    'senha_criada',v_convite.senha_hash is not null,
    'convidados',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',g.id,'nome',g.nome,'principal',g.principal,'status',c.status
      ) order by g.ordem,g.nome)
      from public.convidados g
      left join public.confirmacoes c on c.convidado_id=g.id and c.convite_id=v_convite.id
      where g.convite_id=v_convite.id
    ),'[]'::jsonb)
  );
end; $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'nome',p.nome,'descricao',p.descricao,'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,
    'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',greatest(p.quantidade_total-coalesce(r.assinada,0),0)
  ) order by p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join (
    select presente_id,sum(quantidade)::integer assinada
    from public.reservas_presentes where status='confirmado' group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo=true;
$$;

create or replace function public.confirmar_presentes(p_codigo text,p_itens jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_convite_id uuid; v_item jsonb; v_presente public.presentes%rowtype;
  v_quantidade integer; v_assinada integer;
begin
  select id into v_convite_id from public.convites
  where codigo=upper(trim(p_codigo)) and ativo=true;
  if v_convite_id is null or jsonb_typeof(p_itens)<>'array' or jsonb_array_length(p_itens)=0 then return false; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_quantidade=(v_item->>'quantidade')::integer;
    if v_quantidade is null or v_quantidade<=0 then raise exception 'Quantidade inválida'; end if;
    select * into v_presente from public.presentes
    where id=(v_item->>'presente_id')::uuid and ativo=true for update;
    if not found then raise exception 'Presente inválido'; end if;
    select coalesce(sum(quantidade),0)::integer into v_assinada
    from public.reservas_presentes where presente_id=v_presente.id and status='confirmado';
    if v_assinada+v_quantidade>v_presente.quantidade_total then
      raise exception 'Quantidade indisponível para %',v_presente.nome;
    end if;
    insert into public.reservas_presentes(convite_id,presente_id,quantidade)
    values(v_convite_id,v_presente.id,v_quantidade);
  end loop;
  return true;
end; $$;

create or replace function public.configurar_senha_noivos(p_codigo text,p_senha text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if length(p_senha)<8 then return false; end if;
  update public.convites set senha_hash=crypt(p_senha,gen_salt('bf')),atualizado_em=now()
  where codigo=upper(trim(p_codigo)) and ativo=true and nivel_acesso>=3 and senha_hash is null;
  return found;
end; $$;

create or replace function public.criar_sessao_noivos(p_codigo text,p_senha text,p_token_hash text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select id into v_convite_id from public.convites
  where codigo=upper(trim(p_codigo)) and ativo=true and nivel_acesso>=3
    and senha_hash is not null and senha_hash=crypt(p_senha,senha_hash);
  if v_convite_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
  values(v_convite_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  select convite_id into v_convite_id from public.sessoes_noivos
  where token_hash=p_token_hash and expira_em>now();
  if v_convite_id is null then return null; end if;
  return jsonb_build_object(
    'convidados_total',(select count(*) from public.convidados),
    'confirmados',(select count(*) from public.confirmacoes where status='sim'),
    'nao_comparecem',(select count(*) from public.confirmacoes where status='nao'),
    'aguardando',(select count(*) from public.convidados g where not exists(
      select 1 from public.confirmacoes c where c.convidado_id=g.id)),
    'presentes_assinados',(select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado'),
    'ultimas_confirmacoes',coalesce((
      select jsonb_agg(x order by x.atualizado_em desc) from (
        select g.nome,c.status,c.mensagem,c.atualizado_em
        from public.confirmacoes c join public.convidados g on g.id=c.convidado_id
        order by c.atualizado_em desc limit 8
      ) x
    ),'[]'::jsonb)
  );
end; $$;

revoke all on function public.buscar_convite(text) from public;
revoke all on function public.listar_presentes() from public;
revoke all on function public.confirmar_presentes(text,jsonb) from public;
revoke all on function public.configurar_senha_noivos(text,text) from public;
revoke all on function public.criar_sessao_noivos(text,text,text) from public;
revoke all on function public.dashboard_noivos(text) from public;
grant execute on function public.buscar_convite(text) to anon,authenticated;
grant execute on function public.listar_presentes() to anon,authenticated;
grant execute on function public.confirmar_presentes(text,jsonb) to anon,authenticated;
grant execute on function public.configurar_senha_noivos(text,text) to anon,authenticated;
grant execute on function public.criar_sessao_noivos(text,text,text) to anon,authenticated;
grant execute on function public.dashboard_noivos(text) to anon,authenticated;

update public.convites
set nivel_acesso=3,manuais=array['padrinhos'],atualizado_em=now()
where codigo='GA2026';

insert into public.presentes(nome,descricao,preco_centavos,quantidade_total,ordem)
select * from (values
  ('Jantar na lua de mel','Uma noite especial durante a viagem.',25000,4,1::smallint),
  ('Jogo de cama','Para deixar nosso novo lar ainda mais acolhedor.',32000,3,2::smallint),
  ('Passeio em Maragogi','Uma lembrança inesquecível da lua de mel.',45000,2,3::smallint)
) p(nome,descricao,preco_centavos,quantidade_total,ordem)
where not exists(select 1 from public.presentes);

notify pgrst,'reload schema';
