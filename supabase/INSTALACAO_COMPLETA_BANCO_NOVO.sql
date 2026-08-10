-- INSTALACAO COMPLETA DO BANCO - SITE DE CASAMENTO
-- Gerado para um projeto Supabase NOVO e vazio.
-- Execute uma unica vez no SQL Editor.
--
-- O script cria toda a estrutura, funcoes, RPCs, gatilhos, RLS e permissoes.
-- Nao inclui convidados, presentes, noivos, assessores, pagamentos, mensagens,
-- credenciais ou dados de exemplo. Cria apenas:
--   1) a conta estrutural "admin", sem senha, para o primeiro acesso em /x;
--   2) linhas singleton vazias de configuracao exigidas pelo aplicativo.
--
-- ATENCAO: destinado apenas a banco novo. Nao execute sobre o banco atual.

begin;

-- ============================================================================
-- schema.sql
-- ============================================================================
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

-- ============================================================================
-- migration_002_presentes_manuais_noivos.sql
-- ============================================================================
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

-- ============================================================================
-- migration_003_codigos_individuais.sql
-- ============================================================================
-- Códigos individuais de acesso para cada convidado. Esta etapa precisa vir
-- antes das migrações 008+, que consultam convidados.codigo_individual.
alter table public.convidados
  add column if not exists codigo_individual varchar(6);

create or replace function public.gerar_codigo_individual_unico()
returns varchar
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo varchar(6);
begin
  loop
    v_codigo := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (
      select 1 from public.convites where codigo = v_codigo
    ) and not exists (
      select 1 from public.convidados where codigo_individual = v_codigo
    );
  end loop;
  return v_codigo;
end;
$$;

do $$
declare
  v_id uuid;
begin
  for v_id in
    select id
    from (
      select
        id,
        codigo_individual,
        row_number() over (
          partition by codigo_individual
          order by criado_em, id
        ) as repeticao
      from public.convidados
    ) codigos
    where codigo_individual is null
       or codigo_individual !~ '^[A-Z0-9]{6}$'
       or repeticao > 1
  loop
    update public.convidados
       set codigo_individual = public.gerar_codigo_individual_unico()
     where id = v_id;
  end loop;
end;
$$;

alter table public.convidados
  alter column codigo_individual
    set default public.gerar_codigo_individual_unico(),
  alter column codigo_individual set not null;

alter table public.convidados
  drop constraint if exists convidados_codigo_individual_formato_check;

alter table public.convidados
  add constraint convidados_codigo_individual_formato_check
  check (
    codigo_individual = upper(codigo_individual)
    and codigo_individual ~ '^[A-Z0-9]{6}$'
  );

create unique index if not exists convidados_codigo_individual_unico
  on public.convidados (codigo_individual);

revoke all on function public.gerar_codigo_individual_unico() from public;
grant execute on function public.gerar_codigo_individual_unico() to service_role;
notify pgrst, 'reload schema';

-- ============================================================================
-- migration_004_gestao_dashboard.sql
-- ============================================================================
-- Dashboard detalhado, gestores de convites e administração dos convidados.
alter table public.convidados
  add column if not exists pode_gerenciar boolean not null default false;

update public.convidados set pode_gerenciar=true where principal=true;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype;
begin
  select * into v_convite from public.convites where codigo=upper(trim(p_codigo)) and ativo=true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',v_convite.codigo,'nome_familia',v_convite.nome_familia,
    'funcao_cortejo',v_convite.funcao_cortejo,'instrucoes_cortejo',v_convite.instrucoes_cortejo,
    'nivel_acesso',v_convite.nivel_acesso,'manuais',v_convite.manuais,
    'senha_criada',v_convite.senha_hash is not null,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,'status',c.status
    ) order by g.ordem,g.nome) from public.convidados g
    left join public.confirmacoes c on c.convidado_id=g.id and c.convite_id=v_convite.id
    where g.convite_id=v_convite.id),'[]'::jsonb)
  );
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
    'aguardando',(select count(*) from public.convidados g where not exists(select 1 from public.confirmacoes c where c.convidado_id=g.id)),
    'presentes_assinados',(select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado'),
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',cv.codigo,'conjunto',cv.nome_familia,
      'funcao',cv.funcao_cortejo,'nivel_acesso',cv.nivel_acesso
    ) order by cv.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites cv on cv.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id),'[]'::jsonb),
    'reservas',coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'convidado',cv.nome_familia,'codigo',cv.codigo,'presente',p.nome,
      'quantidade',r.quantidade,'criado_em',r.criado_em
    ) order by r.criado_em desc)
    from public.reservas_presentes r join public.convites cv on cv.id=r.convite_id
    join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb),
    'ultimas_confirmacoes',coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (
      select g.nome,c.status,c.mensagem,c.atualizado_em from public.confirmacoes c
      join public.convidados g on g.id=c.convidado_id order by c.atualizado_em desc limit 8
    ) x),'[]'::jsonb)
  );
end; $$;

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_admin uuid; v_convite_id uuid; v_item jsonb;
begin
  select convite_id into v_admin from public.sessoes_noivos
  where token_hash=p_token_hash and expira_em>now();
  if v_admin is null then return false; end if;

  if p_acao='adicionar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    if v_convite_id is null then return false; end if;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem)
    values(v_convite_id,trim(p_dados->>'nome'),coalesce((p_dados->>'principal')::boolean,false),
      coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1));
  elsif p_acao='editar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    if v_convite_id is null then return false; end if;
    update public.convidados set convite_id=v_convite_id,nome=trim(p_dados->>'nome'),
      principal=coalesce((p_dados->>'principal')::boolean,false),
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false)
    where id=(p_dados->>'id')::uuid;
  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
  elsif p_acao='criar_conjunto' then
    insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo,manuais)
    values(upper(p_dados->>'codigo'),trim(p_dados->>'conjunto'),
      coalesce((p_dados->>'nivel_acesso')::smallint,1),nullif(trim(p_dados->>'funcao'),''),
      coalesce(array(select jsonb_array_elements_text(p_dados->'manuais')),'{}'))
    on conflict(codigo) do update set nome_familia=excluded.nome_familia,
      nivel_acesso=excluded.nivel_acesso,funcao_cortejo=excluded.funcao_cortejo,
      manuais=excluded.manuais,atualizado_em=now();
  elsif p_acao='importar' then
    for v_item in select * from jsonb_array_elements(p_dados->'linhas') loop
      insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo)
      values(upper(v_item->>'codigo'),trim(v_item->>'conjunto'),
        coalesce((v_item->>'nivel_acesso')::smallint,1),nullif(trim(v_item->>'funcao'),''))
      on conflict(codigo) do update set nome_familia=excluded.nome_familia,
        nivel_acesso=excluded.nivel_acesso,funcao_cortejo=excluded.funcao_cortejo;
      select id into v_convite_id from public.convites where codigo=upper(v_item->>'codigo');
      insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem)
      values(v_convite_id,trim(v_item->>'nome'),
        coalesce((v_item->>'principal')::boolean,false),
        coalesce((v_item->>'pode_gerenciar')::boolean,false),
        coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1));
    end loop;
  else return false;
  end if;
  return true;
end; $$;

revoke all on function public.administrar_convidados(text,text,jsonb) from public;
grant execute on function public.administrar_convidados(text,text,jsonb) to anon,authenticated;
grant execute on function public.dashboard_noivos(text) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_005_assessoria_funcoes.sql
-- ============================================================================
-- Perfis de acesso, funções individuais e confirmação pelo dashboard.
alter table public.convites add column if not exists perfil_acesso text not null default 'convidado'
  check (perfil_acesso in ('convidado','cortejo','noivos','assessoria','admin'));
alter table public.convidados add column if not exists funcao text;


create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.convites%rowtype;
begin
  select * into v from public.convites where codigo=upper(trim(p_codigo)) and ativo=true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',v.codigo,'nome_familia',v.nome_familia,'funcao_cortejo',v.funcao_cortejo,
    'instrucoes_cortejo',v.instrucoes_cortejo,'nivel_acesso',v.nivel_acesso,
    'perfil_acesso',v.perfil_acesso,'manuais',v.manuais,'senha_criada',v.senha_hash is not null,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'funcao',coalesce(g.funcao,v.funcao_cortejo),'status',cf.status
    ) order by g.ordem,g.nome) from public.convidados g left join public.confirmacoes cf
      on cf.convidado_id=g.id where g.convite_id=v.id),'[]'::jsonb)
  );
end; $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_perfil text;
begin
  select s.convite_id,c.perfil_acesso into v_convite_id,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_convite_id is null then return null; end if;
  return jsonb_build_object(
    'perfil',v_perfil,
    'convidados_total',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin')),
    'confirmados',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='sim' and c.perfil_acesso not in ('assessoria','admin')),
    'nao_comparecem',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='nao' and c.perfil_acesso not in ('assessoria','admin')),
    'aguardando',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin') and not exists(select 1 from public.confirmacoes cf where cf.convidado_id=g.id)),
    'presentes_assinados',case when v_perfil='assessoria' then 0 else (select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado') end,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',c.codigo,'conjunto',c.nome_familia,
      'funcao',coalesce(g.funcao,c.funcao_cortejo),'nivel_acesso',c.nivel_acesso,
      'protegido',c.perfil_acesso='noivos'
    ) order by c.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites c on c.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id
    where c.perfil_acesso not in ('assessoria','admin')),'[]'::jsonb),
    'reservas',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'convidado',c.nome_familia,
        'codigo',c.codigo,'presente',p.nome,'quantidade',r.quantidade,'criado_em',r.criado_em)
        order by r.criado_em desc)
      from public.reservas_presentes r join public.convites c on c.id=r.convite_id
      join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb) end,
    'ultimas_confirmacoes',coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (
      select g.nome,cf.status,cf.mensagem,cf.atualizado_em from public.confirmacoes cf
      join public.convidados g on g.id=cf.convidado_id order by cf.atualizado_em desc limit 8
    ) x),'[]'::jsonb)
  );
end; $$;

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_admin uuid; v_perfil text; v_convite_id uuid; v_alvo_perfil text; v_item jsonb; v_status text;
begin
  select s.convite_id,c.perfil_acesso into v_admin,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_admin is null then return false; end if;
  if v_perfil='assessoria' and p_acao not in ('editar_restrito','presenca') then return false; end if;

  if p_acao in ('editar','editar_restrito','remover','presenca') then
    select c.id,c.perfil_acesso into v_convite_id,v_alvo_perfil
    from public.convidados g join public.convites c on c.id=g.convite_id
    where g.id=(p_dados->>'id')::uuid;
    if v_convite_id is null then return false; end if;
    if v_perfil='noivos' and v_alvo_perfil='noivos' then return false; end if;
  end if;

  if p_acao='adicionar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
    values(v_convite_id,trim(p_dados->>'nome'),coalesce((p_dados->>'principal')::boolean,false),
      coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
      nullif(trim(p_dados->>'funcao'),''));
  elsif p_acao='editar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    update public.convidados set convite_id=v_convite_id,nome=trim(p_dados->>'nome'),
      principal=coalesce((p_dados->>'principal')::boolean,false),
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      funcao=nullif(trim(p_dados->>'funcao'),'') where id=(p_dados->>'id')::uuid;
  elsif p_acao='editar_restrito' then
    update public.convidados set funcao=nullif(trim(p_dados->>'funcao'),'')
    where id=(p_dados->>'id')::uuid;
  elsif p_acao='presenca' then
    v_status=p_dados->>'status';
    if v_status='aguardando' then
      delete from public.confirmacoes where convidado_id=(p_dados->>'id')::uuid;
    elsif v_status in ('sim','nao') then
      insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
      values(v_convite_id,(p_dados->>'id')::uuid,v_status,now())
      on conflict(convite_id,convidado_id) do update set status=excluded.status,atualizado_em=now();
    else return false; end if;
  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
  elsif p_acao='importar' then
    for v_item in select * from jsonb_array_elements(p_dados->'linhas') loop
      insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo)
      values(upper(v_item->>'codigo'),trim(v_item->>'conjunto'),coalesce((v_item->>'nivel_acesso')::smallint,1),nullif(trim(v_item->>'funcao'),''))
      on conflict(codigo) do update set nome_familia=excluded.nome_familia,nivel_acesso=excluded.nivel_acesso;
      select id into v_convite_id from public.convites where codigo=upper(v_item->>'codigo');
      insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
      values(v_convite_id,trim(v_item->>'nome'),coalesce((v_item->>'principal')::boolean,false),
        coalesce((v_item->>'pode_gerenciar')::boolean,false),
        coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
        nullif(trim(v_item->>'funcao'),''));
    end loop;
  else return false; end if;
  return true;
end; $$;

grant execute on function public.dashboard_noivos(text) to anon,authenticated;
grant execute on function public.administrar_convidados(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_008_acesso_assessoria_individual.sql
-- ============================================================================
-- Cada assessora recebe um conjunto técnico próprio com perfil de assessoria.
-- O acesso privilegiado passa a ser resolvido pelo código individual da pessoa.

create or replace function public.gerar_codigo_conjunto()
returns text language plpgsql security definer set search_path=public as $$
declare v text;
begin
  loop
    v:=upper(substr(md5(gen_random_uuid()::text),1,6));
    exit when not exists(select 1 from public.convites where codigo=v);
  end loop;
  return v;
end; $$;

create or replace function public.preparar_perfil_assessoria()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_perfil text; v_convite uuid; v_codigo text;
begin
  if lower(coalesce(new.funcao,'')) in ('assessora','assessor') then
    select perfil_acesso into v_perfil from public.convites where id=new.convite_id;
    if coalesce(v_perfil,'')<>'assessoria' then
      v_codigo:=public.gerar_codigo_conjunto();
      insert into public.convites(
        codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,manuais,ativo
      ) values(
        v_codigo,'Assessoria — '||new.nome,'Assessora',3,'assessoria','{}',true
      ) returning id into v_convite;
      new.convite_id:=v_convite;
      new.pode_gerenciar:=true;
      new.principal:=false;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_preparar_perfil_assessoria on public.convidados;
create trigger trg_preparar_perfil_assessoria
before insert or update of funcao on public.convidados
for each row execute function public.preparar_perfil_assessoria();

-- Corrige assessoras já adicionadas em conjuntos comuns.
do $$
declare r record; v_convite uuid;
begin
  for r in
    select g.id,g.nome from public.convidados g join public.convites c on c.id=g.convite_id
    where lower(coalesce(g.funcao,'')) in ('assessora','assessor')
      and c.perfil_acesso<>'assessoria'
  loop
    insert into public.convites(
      codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,manuais,ativo
    ) values(
      public.gerar_codigo_conjunto(),'Assessoria — '||r.nome,'Assessora',3,'assessoria','{}',true
    ) returning id into v_convite;
    update public.convidados set convite_id=v_convite,pode_gerenciar=true,principal=false
      where id=r.id;
  end loop;
end $$;

create or replace function public.configurar_senha_noivos(p_codigo text,p_senha text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  if length(p_senha)<8 then return false; end if;
  select c.id into v_convite_id from public.convidados g
  join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_convite_id is null then
    select id into v_convite_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_convite_id is null then return false; end if;
  update public.convites set senha_hash=crypt(p_senha,gen_salt('bf')),atualizado_em=now()
    where id=v_convite_id and senha_hash is null;
  return found;
end; $$;

create or replace function public.criar_sessao_noivos(
  p_codigo text,p_senha text,p_token_hash text
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select c.id into v_convite_id from public.convidados g
  join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin')
    and c.senha_hash is not null and c.senha_hash=crypt(p_senha,c.senha_hash);
  if v_convite_id is null then
    select id into v_convite_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin'
      and senha_hash is not null and senha_hash=crypt(p_senha,senha_hash);
  end if;
  if v_convite_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_convite_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

grant execute on function public.configurar_senha_noivos(text,text) to anon,authenticated;
grant execute on function public.criar_sessao_noivos(text,text,text) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_009_primeiro_acesso.sql
-- ============================================================================
-- Estado e criação de senha com resultado explícito para noivos, assessoria e administrador.
create or replace function public.estado_acesso(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return null; end if;
  return jsonb_build_object('perfil',c.perfil_acesso,'senha_criada',c.senha_hash is not null);
end; $$;

create or replace function public.criar_senha_inicial(p_codigo text,p_senha text)
returns text language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  if length(p_senha)<8 or length(p_senha)>128 then return 'senha_invalida'; end if;
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return 'sem_acesso'; end if;
  if c.senha_hash is not null then return 'ja_criada'; end if;
  update public.convites set senha_hash=crypt(p_senha,gen_salt('bf')),atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

grant execute on function public.estado_acesso(text) to anon,authenticated;
grant execute on function public.criar_senha_inicial(text,text) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_010_pgcrypto_senhas.sql
-- ============================================================================
-- Corrige o acesso ao pgcrypto nas funções SECURITY DEFINER.
create or replace function public.criar_senha_inicial(p_codigo text,p_senha text)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare c public.convites%rowtype;
begin
  if length(p_senha)<8 or length(p_senha)>128 then return 'senha_invalida'; end if;
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return 'sem_acesso'; end if;
  if c.senha_hash is not null then return 'ja_criada'; end if;
  update public.convites
    set senha_hash=extensions.crypt(p_senha,extensions.gen_salt('bf')),atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

create or replace function public.configurar_senha_noivos(p_codigo text,p_senha text)
returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare v_id uuid;
begin
  if length(p_senha)<8 or length(p_senha)>128 then return false; end if;
  select c.id into v_id from public.convidados g join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_id is null then return false; end if;
  update public.convites
    set senha_hash=extensions.crypt(p_senha,extensions.gen_salt('bf')),atualizado_em=now()
    where id=v_id and senha_hash is null;
  return found;
end; $$;

create or replace function public.criar_sessao_noivos(
  p_codigo text,p_senha text,p_token_hash text
) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare v_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select c.id into v_id from public.convidados g join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin')
    and c.senha_hash is not null
    and c.senha_hash=extensions.crypt(p_senha,c.senha_hash);
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin'
      and senha_hash is not null
      and senha_hash=extensions.crypt(p_senha,senha_hash);
  end if;
  if v_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

grant execute on function public.criar_senha_inicial(text,text) to anon,authenticated;
grant execute on function public.configurar_senha_noivos(text,text) to anon,authenticated;
grant execute on function public.criar_sessao_noivos(text,text,text) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_011_argon2id_backend.sql
-- ============================================================================
-- O backend Next.js passa a gerar e verificar Argon2id.
-- Estas funções NÃO são públicas: exigem a chave secreta/service-role.

create or replace function public.resolver_acesso_backend(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return null; end if;
  return jsonb_build_object(
    'convite_id',c.id,'perfil',c.perfil_acesso,
    'senha_hash',c.senha_hash,'senha_criada',c.senha_hash is not null
  );
end; $$;

create or replace function public.salvar_hash_argon2_backend(p_codigo text,p_hash text)
returns text language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  if p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$' then return 'hash_invalido'; end if;
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return 'sem_acesso'; end if;
  if c.senha_hash is not null then return 'ja_criada'; end if;
  update public.convites set senha_hash=p_hash,atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

create or replace function public.criar_sessao_backend(p_codigo text,p_token_hash text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select cv.id into v_id from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

revoke all on function public.resolver_acesso_backend(text) from public,anon,authenticated;
revoke all on function public.salvar_hash_argon2_backend(text,text) from public,anon,authenticated;
revoke all on function public.criar_sessao_backend(text,text) from public,anon,authenticated;
grant execute on function public.resolver_acesso_backend(text) to service_role;
grant execute on function public.salvar_hash_argon2_backend(text,text) to service_role;
grant execute on function public.criar_sessao_backend(text,text) to service_role;

-- Hashes bcrypt antigos não podem ser verificados pelo novo backend sem receber a senha no banco.
-- Exige criação de uma nova senha Argon2id no próximo acesso e encerra sessões antigas.
update public.convites set senha_hash=null,atualizado_em=now()
where perfil_acesso in ('noivos','assessoria','admin')
  and senha_hash is not null and senha_hash not like '$argon2id$%';
delete from public.sessoes_noivos;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_012_grupos_mensagens.sql
-- ============================================================================
-- Grupos explícitos no dashboard e caixa de mensagens dos noivos.

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_perfil text;
begin
  select s.convite_id,c.perfil_acesso into v_convite_id,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_convite_id is null then return null; end if;
  return jsonb_build_object(
    'perfil',v_perfil,
    'convidados_total',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin')),
    'confirmados',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='sim' and c.perfil_acesso not in ('assessoria','admin')),
    'nao_comparecem',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='nao' and c.perfil_acesso not in ('assessoria','admin')),
    'aguardando',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin') and not exists(select 1 from public.confirmacoes cf where cf.convidado_id=g.id)),
    'presentes_assinados',case when v_perfil='assessoria' then 0 else (select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado') end,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',c.codigo,
      'codigo_individual',g.codigo_individual,'conjunto',c.nome_familia,
      'funcao',coalesce(g.funcao,c.funcao_cortejo),'nivel_acesso',c.nivel_acesso,
      'protegido',c.perfil_acesso='noivos'
    ) order by c.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites c on c.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id
    where c.perfil_acesso not in ('assessoria','admin')),'[]'::jsonb),
    'grupos',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,'codigo',c.codigo,'titulo',c.nome_familia,
        'total',(select count(*) from public.convidados g where g.convite_id=c.id),
        'protegido',c.perfil_acesso='noivos'
      ) order by c.nome_familia)
      from public.convites c where c.ativo=true and c.perfil_acesso not in ('assessoria','admin')
    ),'[]'::jsonb) end,
    'mensagens',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'grupo',x.grupo,'codigo',x.codigo,'mensagem',x.mensagem,'atualizado_em',x.atualizado_em
      ) order by x.atualizado_em desc) from (
        select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em
        from public.confirmacoes cf join public.convites c on c.id=cf.convite_id
        where nullif(trim(cf.mensagem),'') is not null
        group by cf.convite_id,c.nome_familia,c.codigo,cf.mensagem
        order by max(cf.atualizado_em) desc limit 200
      ) x
    ),'[]'::jsonb) end,
    'reservas',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'convidado',c.nome_familia,
        'codigo',c.codigo,'presente',p.nome,'quantidade',r.quantidade,'criado_em',r.criado_em)
        order by r.criado_em desc)
      from public.reservas_presentes r join public.convites c on c.id=r.convite_id
      join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb) end,
    'ultimas_confirmacoes',coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (
      select g.nome,cf.status,cf.mensagem,cf.atualizado_em from public.confirmacoes cf
      join public.convidados g on g.id=cf.convidado_id order by cf.atualizado_em desc limit 8
    ) x),'[]'::jsonb)
  );
end; $$;

create or replace function public.administrar_grupos(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_perfil text; v_alvo public.convites%rowtype; v_codigo text; v_titulo text;
begin
  select c.perfil_acesso into v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','admin');
  if v_perfil is null then return false; end if;

  v_codigo:=upper(trim(coalesce(p_dados->>'codigo','')));
  v_titulo:=trim(coalesce(p_dados->>'titulo',''));
  if v_codigo !~ '^[A-Z0-9]{6}$' or length(v_titulo)<2 or length(v_titulo)>100 then return false; end if;

  if p_acao='criar' then
    if exists(select 1 from public.convites where codigo=v_codigo) then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_titulo,1,'convidado',true);
  elsif p_acao='editar' then
    select * into v_alvo from public.convites where id=(p_dados->>'id')::uuid;
    if not found or v_alvo.perfil_acesso in ('assessoria','admin') then return false; end if;
    if v_perfil='noivos' and v_alvo.perfil_acesso='noivos' then return false; end if;
    if exists(select 1 from public.convites where codigo=v_codigo and id<>v_alvo.id) then return false; end if;
    update public.convites set codigo=v_codigo,nome_familia=v_titulo,atualizado_em=now()
    where id=v_alvo.id;
  else return false; end if;
  return true;
exception when invalid_text_representation then return false;
end; $$;

revoke all on function public.administrar_grupos(text,text,jsonb) from public;
grant execute on function public.dashboard_noivos(text) to anon,authenticated;
grant execute on function public.administrar_grupos(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_013_grupo_individual_automatico.sql
-- ============================================================================
-- Ao adicionar uma pessoa manualmente, cria um grupo individual.
-- O código do grupo é exatamente igual ao código individual do convidado.

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_admin uuid;
  v_perfil text;
  v_convite_id uuid;
  v_convite_anterior uuid;
  v_alvo_perfil text;
  v_item jsonb;
  v_status text;
  v_codigo text;
  v_nome text;
  v_funcao text;
  v_perfil_novo text;
  v_nivel_novo smallint;
  v_codigo_individual text;
  v_grupo_individual boolean := false;
begin
  select s.convite_id,c.perfil_acesso into v_admin,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_admin is null then return false; end if;
  if v_perfil='assessoria' and p_acao not in ('editar_restrito','presenca') then return false; end if;

  if p_acao in ('editar','editar_restrito','remover','presenca') then
    select c.id,c.perfil_acesso,g.codigo_individual,
      c.codigo=g.codigo_individual
    into v_convite_id,v_alvo_perfil,v_codigo_individual,v_grupo_individual
    from public.convidados g join public.convites c on c.id=g.convite_id
    where g.id=(p_dados->>'id')::uuid;
    if v_convite_id is null then return false; end if;
    if v_perfil='noivos' and v_alvo_perfil='noivos' then return false; end if;
  end if;

  if p_acao='adicionar' then
    v_nome:=trim(coalesce(p_dados->>'nome',''));
    v_funcao:=nullif(trim(coalesce(p_dados->>'funcao','')),'');
    if length(v_nome)<2 or length(v_nome)>150 then return false; end if;

    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
    end loop;

    if lower(coalesce(v_funcao,'')) in ('assessora','assessor') then
      v_perfil_novo:='assessoria';
      v_nivel_novo:=3;
    else
      v_perfil_novo:='convidado';
      v_nivel_novo:=1;
    end if;

    insert into public.convites(
      codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,ativo
    ) values(
      v_codigo,
      case when v_perfil_novo='assessoria' then 'Assessoria — '||v_nome else v_nome end,
      case when v_perfil_novo='assessoria' then 'Assessora' else null end,
      v_nivel_novo,v_perfil_novo,true
    ) returning id into v_convite_id;

    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual
    ) values(
      v_convite_id,v_nome,false,true,1,v_funcao,v_codigo
    );

  elsif p_acao='editar' then
    v_convite_anterior:=v_convite_id;
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    if v_convite_id is null then return false; end if;
    update public.confirmacoes set convite_id=v_convite_id
    where convidado_id=(p_dados->>'id')::uuid;
    update public.convidados set convite_id=v_convite_id,nome=trim(p_dados->>'nome'),
      principal=false,
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      funcao=nullif(trim(p_dados->>'funcao'),'') where id=(p_dados->>'id')::uuid;
    if v_grupo_individual and v_convite_anterior<>v_convite_id then
      delete from public.convites c where c.id=v_convite_anterior
        and not exists(select 1 from public.convidados g where g.convite_id=c.id)
        and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    end if;

  elsif p_acao='editar_restrito' then
    update public.convidados set funcao=nullif(trim(p_dados->>'funcao'),'')
    where id=(p_dados->>'id')::uuid;

  elsif p_acao='presenca' then
    v_status=p_dados->>'status';
    if v_status='aguardando' then
      delete from public.confirmacoes where convidado_id=(p_dados->>'id')::uuid;
    elsif v_status in ('sim','nao') then
      insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
      values(v_convite_id,(p_dados->>'id')::uuid,v_status,now())
      on conflict(convite_id,convidado_id) do update
        set status=excluded.status,atualizado_em=now();
    else return false; end if;

  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
    if v_grupo_individual then
      delete from public.convites c where c.id=v_convite_id
        and not exists(select 1 from public.convidados g where g.convite_id=c.id)
        and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    end if;

  elsif p_acao='importar' then
    for v_item in select * from jsonb_array_elements(p_dados->'linhas') loop
      insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo)
      values(
        upper(v_item->>'codigo'),trim(v_item->>'conjunto'),
        coalesce((v_item->>'nivel_acesso')::smallint,1),
        nullif(trim(v_item->>'funcao'),'')
      )
      on conflict(codigo) do update
        set nome_familia=excluded.nome_familia,nivel_acesso=excluded.nivel_acesso;
      select id into v_convite_id from public.convites where codigo=upper(v_item->>'codigo');
      insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
      values(
        v_convite_id,trim(v_item->>'nome'),false,
        coalesce((v_item->>'pode_gerenciar')::boolean,false),
        coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
        nullif(trim(v_item->>'funcao'),'')
      );
    end loop;
  else
    return false;
  end if;
  return true;
exception
  when unique_violation or invalid_text_representation or not_null_violation then
    return false;
end; $$;

revoke all on function public.administrar_convidados(text,text,jsonb) from public;
grant execute on function public.administrar_convidados(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_014_importacao_codigos_automaticos.sql
-- ============================================================================
-- Importação de convidados com geração automática de códigos individuais.
-- Cada pessoa importada recebe inicialmente um grupo individual com o mesmo código.

create or replace function public.importar_convidados_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer language plpgsql security definer set search_path=public as $$
declare
  v_perfil text;
  v_item jsonb;
  v_codigo text;
  v_nome text;
  v_funcao text;
  v_convite_id uuid;
  v_total integer := 0;
  v_perfil_novo text;
  v_nivel_novo smallint;
begin
  select c.perfil_acesso into v_perfil
  from public.sessoes_noivos s
  join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash
    and s.expira_em>now()
    and c.perfil_acesso in ('noivos','admin');

  if v_perfil is null then return -1; end if;
  if jsonb_typeof(p_linhas)<>'array'
    or jsonb_array_length(p_linhas)<1
    or jsonb_array_length(p_linhas)>1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(coalesce(v_item->>'nome',''));
    v_funcao:=nullif(trim(coalesce(v_item->>'funcao','')),'');
    if length(v_nome)<2 or length(v_nome)>150 then return -2; end if;

    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
    end loop;

    if lower(coalesce(v_funcao,'')) in ('assessora','assessor') then
      v_perfil_novo:='assessoria';
      v_nivel_novo:=3;
    else
      v_perfil_novo:='convidado';
      v_nivel_novo:=1;
    end if;

    insert into public.convites(
      codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,ativo
    ) values(
      v_codigo,
      case when v_perfil_novo='assessoria' then 'Assessoria — '||v_nome else v_nome end,
      case when v_perfil_novo='assessoria' then 'Assessora' else null end,
      v_nivel_novo,v_perfil_novo,true
    ) returning id into v_convite_id;

    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual
    ) values(
      v_convite_id,v_nome,false,true,1,v_funcao,v_codigo
    );
    v_total:=v_total+1;
  end loop;

  return v_total;
exception
  when unique_violation or invalid_text_representation or not_null_violation then
    return -2;
end; $$;

revoke all on function public.importar_convidados_automatico(text,jsonb) from public;
grant execute on function public.importar_convidados_automatico(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_015_organizacao_admin_expiracao.sql
-- ============================================================================
-- Administração principal, contas da organização e validade dos convites.
-- Execute depois das migrações 001–014.

create table if not exists public.organizacao (
  id uuid primary key default gen_random_uuid(),
  usuario text not null unique check (usuario ~ '^[a-z0-9._-]{3,40}$'),
  codigo varchar(6) unique check (codigo is null or (codigo = upper(codigo) and codigo ~ '^[A-Z0-9]{6}$')),
  nome text not null check (length(trim(nome)) between 2 and 150),
  funcao text not null check (funcao in ('administrador', 'noivo', 'noiva', 'assessoria')),
  administrador boolean not null default false,
  principal boolean not null default false,
  senha_hash text,
  exige_troca_senha boolean not null default false,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (not principal or (administrador and usuario = 'admin'))
);

create unique index if not exists organizacao_admin_principal_unico
  on public.organizacao (principal) where principal = true;

create table if not exists public.sessoes_organizacao (
  id uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null references public.organizacao(id) on delete cascade,
  token_hash text not null unique,
  expira_em timestamptz not null,
  criado_em timestamptz not null default now()
);

alter table public.convites
  add column if not exists expira_em timestamptz,
  add column if not exists sem_expiracao boolean not null default false;

-- Convites existentes sem data recebem sete dias a partir desta migração.
update public.convites
set expira_em = coalesce(expira_em, now() + interval '7 days')
where perfil_acesso not in ('noivos', 'assessoria', 'admin')
  and sem_expiracao = false;

-- Migra noivos e assessoria existentes para a organização.
insert into public.organizacao (usuario, codigo, nome, funcao, administrador, principal, senha_hash)
select
  lower(coalesce(nullif(regexp_replace(g.nome, '[^A-Za-z0-9]+', '.', 'g'), ''), 'organizacao')) ||
    '.' || lower(substr(md5(g.id::text), 1, 4)),
  g.codigo_individual,
  g.nome,
  case
    when lower(coalesce(g.funcao, c.funcao_cortejo, '')) like '%noiva%' then 'noiva'
    when lower(coalesce(g.funcao, c.funcao_cortejo, '')) like '%noivo%' then 'noivo'
    else 'assessoria'
  end,
  false,
  false,
  c.senha_hash
from public.convidados g
join public.convites c on c.id = g.convite_id
where c.perfil_acesso in ('noivos', 'assessoria')
on conflict (codigo) do nothing;

-- O administrador principal sempre se chama admin e não usa código.
insert into public.organizacao (
  usuario, codigo, nome, funcao, administrador, principal, senha_hash
)
select 'admin', null, 'Administrador principal', 'administrador', true, true, c.senha_hash
from public.convites c
where c.perfil_acesso = 'admin'
order by c.criado_em
limit 1
on conflict (usuario) do update set
  administrador = true,
  principal = true,
  funcao = 'administrador',
  codigo = null;

insert into public.organizacao (
  usuario, codigo, nome, funcao, administrador, principal
)
values ('admin', null, 'Administrador principal', 'administrador', true, true)
on conflict (usuario) do update set
  administrador = true,
  principal = true,
  funcao = 'administrador',
  codigo = null;

-- Contas da organização deixam de integrar convidados.
delete from public.convidados g
using public.convites c
where g.convite_id = c.id
  and c.perfil_acesso in ('noivos', 'assessoria', 'admin');

delete from public.convites c
where c.perfil_acesso in ('noivos', 'assessoria', 'admin')
  and not exists (select 1 from public.convidados g where g.convite_id = c.id)
  and not exists (select 1 from public.reservas_presentes r where r.convite_id = c.id);

alter table public.organizacao enable row level security;
alter table public.sessoes_organizacao enable row level security;
revoke all on public.organizacao, public.sessoes_organizacao from anon, authenticated;

create or replace function public.estado_organizacao(p_identificador text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.organizacao%rowtype;
begin
  select * into v from public.organizacao
  where ativo and (
    lower(usuario) = lower(trim(p_identificador))
    or codigo = upper(trim(p_identificador))
  );
  if not found then return null; end if;
  return jsonb_build_object(
    'nome', v.nome, 'funcao', v.funcao, 'perfil',
    case when v.administrador then 'admin' else case when v.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end end,
    'senha_criada', v.senha_hash is not null,
    'exige_troca_senha', v.exige_troca_senha,
    'codigo', v.codigo
  );
end $$;

create or replace function public.resolver_conta_backend(p_identificador text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.organizacao%rowtype;
begin
  select * into v from public.organizacao
  where ativo and (
    lower(usuario) = lower(trim(p_identificador))
    or codigo = upper(trim(p_identificador))
  );
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v.id, 'senha_hash', v.senha_hash, 'principal', v.principal,
    'administrador', v.administrador, 'exige_troca_senha', v.exige_troca_senha
  );
end $$;

create or replace function public.salvar_hash_conta_backend(p_identificador text, p_hash text)
returns text language plpgsql security definer set search_path=public as $$
begin
  if p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$' then return 'hash_invalido'; end if;
  update public.organizacao set senha_hash=p_hash, exige_troca_senha=false, atualizado_em=now()
  where ativo
    and (lower(usuario)=lower(trim(p_identificador)) or codigo=upper(trim(p_identificador)))
    and senha_hash is null;
  if found then return 'criada'; end if;
  if exists(select 1 from public.organizacao where ativo and (lower(usuario)=lower(trim(p_identificador)) or codigo=upper(trim(p_identificador))))
    then return 'ja_criada'; end if;
  return 'sem_acesso';
end $$;

create or replace function public.criar_sessao_organizacao_backend(p_identificador text, p_token_hash text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  delete from public.sessoes_organizacao where expira_em <= now();
  select id into v_id from public.organizacao
  where ativo and (lower(usuario)=lower(trim(p_identificador)) or codigo=upper(trim(p_identificador)));
  if v_id is null then return false; end if;
  insert into public.sessoes_organizacao(organizacao_id,token_hash,expira_em)
  values(v_id,p_token_hash,now()+interval '7 days');
  return true;
end $$;

create or replace function public.alterar_senha_organizacao_backend(
  p_token_hash text, p_novo_hash text
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_novo_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$' then return false; end if;
  update public.organizacao o set senha_hash=p_novo_hash, exige_troca_senha=false, atualizado_em=now()
  where exists (
    select 1 from public.sessoes_organizacao s
    where s.organizacao_id=o.id and s.token_hash=p_token_hash and s.expira_em>now()
  );
  return found;
end $$;

create or replace function public.resolver_conta_por_sessao_backend(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.organizacao%rowtype;
begin
  select o.* into v
  from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;
  if not found then return null; end if;
  return jsonb_build_object('id',v.id,'senha_hash',v.senha_hash);
end $$;

create or replace function public.administrar_organizacao_backend(
  p_token_hash text, p_acao text, p_dados jsonb, p_hash text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_admin public.organizacao%rowtype;
  v_alvo public.organizacao%rowtype;
  v_codigo text;
  v_usuario text;
begin
  select o.* into v_admin
  from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and o.administrador;
  if not found then return jsonb_build_object('ok',false); end if;

  if p_acao='criar' then
    v_usuario:=lower(trim(p_dados->>'usuario'));
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$' then return jsonb_build_object('ok',false); end if;
    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.organizacao where codigo=v_codigo)
        and not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
    end loop;
    insert into public.organizacao(usuario,codigo,nome,funcao,administrador,senha_hash,exige_troca_senha)
    values(v_usuario,v_codigo,trim(p_dados->>'nome'),p_dados->>'funcao',
      coalesce((p_dados->>'administrador')::boolean,false),p_hash,true);
    return jsonb_build_object('ok',true,'codigo',v_codigo);
  end if;

  select * into v_alvo from public.organizacao where id=(p_dados->>'id')::uuid;
  if not found then return jsonb_build_object('ok',false); end if;

  if p_acao='editar' then
    if v_alvo.principal then return jsonb_build_object('ok',false); end if;
    update public.organizacao set
      nome=trim(p_dados->>'nome'),
      usuario=lower(trim(p_dados->>'usuario')),
      funcao=p_dados->>'funcao',
      administrador=coalesce((p_dados->>'administrador')::boolean,false),
      atualizado_em=now()
    where id=v_alvo.id;
  elsif p_acao='resetar_senha' then
    update public.organizacao set senha_hash=null, exige_troca_senha=false, atualizado_em=now() where id=v_alvo.id;
    delete from public.sessoes_organizacao where organizacao_id=v_alvo.id;
  elsif p_acao='definir_senha' then
    if p_hash is null then return jsonb_build_object('ok',false); end if;
    update public.organizacao set senha_hash=p_hash, exige_troca_senha=true, atualizado_em=now() where id=v_alvo.id;
    delete from public.sessoes_organizacao where organizacao_id=v_alvo.id;
  else return jsonb_build_object('ok',false);
  end if;
  return jsonb_build_object('ok',true);
exception when unique_violation or invalid_text_representation or check_violation then
  return jsonb_build_object('ok',false);
end $$;

create or replace function public.administrar_expiracao(
  p_token_hash text, p_convite_id uuid, p_acao text, p_data timestamptz default null
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva','assessoria'))
  ) then return false; end if;
  if p_acao='resetar_7_dias' then
    update public.convites set expira_em=now()+interval '7 days',sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='definir_data' and p_data is not null then
    update public.convites set expira_em=p_data,sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='expirar' then
    update public.convites set expira_em=now()-interval '1 second',sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='retirar_expiracao' then
    update public.convites set expira_em=null,sem_expiracao=true,atualizado_em=now() where id=p_convite_id;
  else return false; end if;
  return found;
end $$;

-- Funções públicas atualizadas: convidados e organização são fontes separadas.
create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype; v_org public.organizacao%rowtype;
begin
  select * into v_org from public.organizacao where codigo=upper(trim(p_codigo)) and ativo;
  if found then
    return jsonb_build_object(
      'codigo',v_org.codigo,'codigo_conjunto',v_org.codigo,'nome_familia',v_org.nome,
      'funcao_cortejo',v_org.funcao,'instrucoes_cortejo','[]'::jsonb,'convidados','[]'::jsonb,
      'nivel_acesso',3,'perfil_acesso',case when v_org.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end,
      'manuais','[]'::jsonb,'senha_criada',v_org.senha_hash is not null,
      'exige_troca_senha',v_org.exige_troca_senha,'pode_gerenciar',true,'responsaveis','[]'::jsonb,
      'expira_em',null,'expirado',false,'sem_expiracao',true
    );
  end if;
  select * into v_convite from public.convites
  where id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and ativo;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',upper(trim(p_codigo)),'codigo_conjunto',v_convite.codigo,
    'nome_familia',v_convite.nome_familia,'funcao_cortejo',v_convite.funcao_cortejo,
    'instrucoes_cortejo',v_convite.instrucoes_cortejo,'nivel_acesso',v_convite.nivel_acesso,
    'perfil_acesso','convidado','manuais',to_jsonb(coalesce(v_convite.manuais,'{}'::text[])),
    'senha_criada',false,'exige_troca_senha',false,
    'expira_em',v_convite.expira_em,'sem_expiracao',v_convite.sem_expiracao,
    'expirado',(not v_convite.sem_expiracao and v_convite.expira_em<=now()),
    'pode_gerenciar',coalesce((select pode_gerenciar from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),false),
    'responsaveis',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'nome',g.nome,'funcao',g.funcao)) from public.convidados g where g.convite_id=v_convite.id and g.pode_gerenciar),'[]'::jsonb),
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'codigo_individual',g.codigo_individual,'pode_gerenciar',g.pode_gerenciar,
      'funcao',g.funcao,'status',cf.status
    ) order by g.ordem,g.nome) from public.convidados g left join public.confirmacoes cf on cf.convidado_id=g.id where g.convite_id=v_convite.id),'[]'::jsonb)
  );
end $$;

create or replace function public.salvar_confirmacao(
  p_codigo text, p_respostas jsonb, p_mensagem text default null
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_convite_id uuid; v_item jsonb; v_convidado_id uuid; v_status text;
begin
  select c.id into v_convite_id
  from public.convites c
  where c.id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  )
    and c.ativo
    and (c.sem_expiracao or (c.expira_em is not null and c.expira_em>now()));
  if v_convite_id is null or jsonb_typeof(p_respostas)<>'array' then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_convidado_id:=(v_item->>'convidado_id')::uuid;
    v_status:=v_item->>'status';
    if v_status not in ('sim','nao') then return false; end if;
    if not exists(select 1 from public.convidados where id=v_convidado_id and convite_id=v_convite_id) then return false; end if;
    insert into public.confirmacoes(convite_id,convidado_id,status,mensagem,atualizado_em)
    values(v_convite_id,v_convidado_id,v_status,nullif(trim(p_mensagem),''),now())
    on conflict(convite_id,convidado_id) do update set
      status=excluded.status,mensagem=excluded.mensagem,atualizado_em=now();
  end loop;
  return true;
end $$;

-- Dashboard unificado e sem organização na lista de convidados.
create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org public.organizacao%rowtype; v_perfil text;
begin
  select o.* into v_org from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;
  if not found then return null; end if;
  v_perfil:=case when v_org.administrador then 'admin' when v_org.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end;
  return jsonb_build_object(
    'perfil',v_perfil,'conta',jsonb_build_object('id',v_org.id,'nome',v_org.nome,'usuario',v_org.usuario,'funcao',v_org.funcao,'principal',v_org.principal,'exige_troca_senha',v_org.exige_troca_senha),
    'convidados_total',(select count(*) from public.convidados),
    'confirmados',(select count(*) from public.confirmacoes where status='sim'),
    'nao_comparecem',(select count(*) from public.confirmacoes where status='nao'),
    'aguardando',(select count(*) from public.convidados g where not exists(select 1 from public.confirmacoes cf where cf.convidado_id=g.id)),
    'presentes_assinados',case when v_perfil='assessoria' then 0 else (select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado') end,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'convite_id',c.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',c.codigo,'codigo_individual',g.codigo_individual,
      'conjunto',c.nome_familia,'funcao',g.funcao,'nivel_acesso',c.nivel_acesso,'protegido',false,
      'expira_em',c.expira_em,'sem_expiracao',c.sem_expiracao,
      'expirado',(not c.sem_expiracao and c.expira_em<=now())
    ) order by c.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites c on c.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id),'[]'::jsonb),
    'organizacao',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'nome',o.nome,'usuario',o.usuario,'codigo',o.codigo,'funcao',o.funcao,
      'administrador',o.administrador,'principal',o.principal,'senha_criada',o.senha_hash is not null,
      'exige_troca_senha',o.exige_troca_senha
    ) order by o.principal desc,o.nome) from public.organizacao o where o.ativo),'[]'::jsonb),
    'grupos',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'codigo',c.codigo,'titulo',c.nome_familia,'total',(select count(*) from public.convidados g where g.convite_id=c.id),'protegido',false) order by c.nome_familia) from public.convites c where c.ativo),'[]'::jsonb) end,
    'mensagens',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em from public.confirmacoes cf join public.convites c on c.id=cf.convite_id where nullif(trim(cf.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,cf.mensagem limit 200)x),'[]'::jsonb) end,
    'reservas',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'convidado',c.nome_familia,'codigo',c.codigo,'presente',p.nome,'quantidade',r.quantidade,'criado_em',r.criado_em) order by r.criado_em desc) from public.reservas_presentes r join public.convites c on c.id=r.convite_id join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb) end,
    'ultimas_confirmacoes','[]'::jsonb
  );
end $$;

-- Novos convidados sempre começam com sete dias.
create or replace function public.definir_validade_padrao_convite()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.perfil_acesso not in ('noivos','assessoria','admin') and new.expira_em is null and not new.sem_expiracao then
    new.expira_em:=now()+interval '7 days';
  end if;
  return new;
end $$;
drop trigger if exists convite_validade_padrao on public.convites;
create trigger convite_validade_padrao before insert on public.convites
for each row execute function public.definir_validade_padrao_convite();

revoke all on function public.resolver_conta_backend(text), public.salvar_hash_conta_backend(text,text),
  public.criar_sessao_organizacao_backend(text,text), public.alterar_senha_organizacao_backend(text,text),
  public.resolver_conta_por_sessao_backend(text), public.administrar_organizacao_backend(text,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.resolver_conta_backend(text), public.salvar_hash_conta_backend(text,text),
  public.criar_sessao_organizacao_backend(text,text), public.alterar_senha_organizacao_backend(text,text),
  public.resolver_conta_por_sessao_backend(text), public.administrar_organizacao_backend(text,text,jsonb,text)
  to service_role;
grant execute on function public.estado_organizacao(text), public.buscar_convite(text),
  public.salvar_confirmacao(text,jsonb,text), public.dashboard_noivos(text),
  public.administrar_expiracao(text,uuid,text,timestamptz) to anon,authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- migration_016_imagens_presentes.sql
-- ============================================================================
-- Imagens dos itens da lista de presentes.
-- Cada presente pode ter uma ou mais URLs; o site usa a imagem padrão
-- quando o campo está vazio ou quando a imagem externa não carrega.

alter table public.presentes
add column if not exists imagens text[] not null default '{}';

create or replace function public.listar_presentes()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'nome', p.nome,
        'descricao', p.descricao,
        'imagens', coalesce(p.imagens, '{}'),
        'preco_centavos', p.preco_centavos,
        'quantidade_total', p.quantidade_total,
        'quantidade_assinada', coalesce(r.assinada, 0),
        'quantidade_restante',
          greatest(p.quantidade_total - coalesce(r.assinada, 0), 0)
      )
      order by p.ordem, p.nome
    ),
    '[]'::jsonb
  )
  from public.presentes p
  left join (
    select
      presente_id,
      sum(quantidade)::integer as assinada
    from public.reservas_presentes
    where status = 'confirmado'
    group by presente_id
  ) r on r.presente_id = p.id
  where p.ativo = true;
$$;

revoke all
on function public.listar_presentes()
from public;

grant execute
on function public.listar_presentes()
to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- migration_017_corrige_busca_convite.sql
-- ============================================================================
-- Corrige a consulta pública de convites após a separação da organização.
-- A coluna convites.manuais é text[] e precisa ser convertida para jsonb.

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_convite public.convites%rowtype;
  v_org public.organizacao%rowtype;
begin
  select *
  into v_org
  from public.organizacao
  where codigo = upper(trim(p_codigo))
    and ativo;

  if found then
    return jsonb_build_object(
      'codigo', v_org.codigo,
      'codigo_conjunto', v_org.codigo,
      'nome_familia', v_org.nome,
      'funcao_cortejo', v_org.funcao,
      'instrucoes_cortejo', '[]'::jsonb,
      'convidados', '[]'::jsonb,
      'nivel_acesso', 3,
      'perfil_acesso',
        case
          when v_org.funcao in ('noivo', 'noiva') then 'noivos'
          else 'assessoria'
        end,
      'manuais', '[]'::jsonb,
      'senha_criada', v_org.senha_hash is not null,
      'exige_troca_senha', v_org.exige_troca_senha,
      'pode_gerenciar', true,
      'responsaveis', '[]'::jsonb,
      'expira_em', null,
      'expirado', false,
      'sem_expiracao', true
    );
  end if;

  select *
  into v_convite
  from public.convites
  where id = coalesce(
    (
      select convite_id
      from public.convidados
      where codigo_individual = upper(trim(p_codigo))
      limit 1
    ),
    (
      select id
      from public.convites
      where codigo = upper(trim(p_codigo))
      limit 1
    )
  )
    and ativo;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'codigo', upper(trim(p_codigo)),
    'codigo_conjunto', v_convite.codigo,
    'nome_familia', v_convite.nome_familia,
    'funcao_cortejo', v_convite.funcao_cortejo,
    'instrucoes_cortejo', v_convite.instrucoes_cortejo,
    'nivel_acesso', v_convite.nivel_acesso,
    'perfil_acesso', 'convidado',
    'manuais', to_jsonb(coalesce(v_convite.manuais, '{}'::text[])),
    'senha_criada', false,
    'exige_troca_senha', false,
    'expira_em', v_convite.expira_em,
    'sem_expiracao', v_convite.sem_expiracao,
    'expirado',
      (
        not v_convite.sem_expiracao
        and v_convite.expira_em <= now()
      ),
    'pode_gerenciar',
      coalesce(
        (
          select pode_gerenciar
          from public.convidados
          where codigo_individual = upper(trim(p_codigo))
          limit 1
        ),
        false
      ),
    'responsaveis',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', g.id,
              'nome', g.nome,
              'funcao', g.funcao
            )
          )
          from public.convidados g
          where g.convite_id = v_convite.id
            and g.pode_gerenciar
        ),
        '[]'::jsonb
      ),
    'convidados',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', g.id,
              'nome', g.nome,
              'codigo_individual', g.codigo_individual,
              'pode_gerenciar', g.pode_gerenciar,
              'funcao', g.funcao,
              'status', cf.status
            )
            order by g.ordem, g.nome
          )
          from public.convidados g
          left join public.confirmacoes cf
            on cf.convidado_id = g.id
          where g.convite_id = v_convite.id
        ),
        '[]'::jsonb
      )
  );
end;
$$;

revoke all
on function public.buscar_convite(text)
from public;

grant execute
on function public.buscar_convite(text)
to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- migration_017_dashboard_imagens_presentes.sql
-- ============================================================================
-- Edição das imagens dos presentes pelo dashboard dos noivos e administradores.

create or replace function public.administrar_imagens_presente(
  p_token_hash text,
  p_presente_id uuid,
  p_imagens text[]
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permitido boolean;
  v_url text;
begin
  select exists(
    select 1
    from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash
      and s.expira_em > now()
      and o.ativo
      and (o.administrador or o.funcao in ('noivo', 'noiva'))
  ) into v_permitido;

  if not v_permitido or cardinality(coalesce(p_imagens, '{}')) > 10 then
    return false;
  end if;

  foreach v_url in array coalesce(p_imagens, '{}') loop
    if length(v_url) > 1000 or v_url !~* '^https?://' then
      return false;
    end if;
  end loop;

  update public.presentes
  set imagens = coalesce(p_imagens, '{}')
  where id = p_presente_id;

  return found;
end;
$$;

revoke all on function public.administrar_imagens_presente(text, uuid, text[]) from public;
grant execute on function public.administrar_imagens_presente(text, uuid, text[]) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- migration_018_status_criancas_grupos.sql
-- ============================================================================
-- Status automático, horário de expiração e crianças em grupos familiares.

alter table public.convidados
  add column if not exists crianca boolean not null default false,
  add column if not exists idade_confirmada smallint
    check (idade_confirmada between 0 and 120),
  add column if not exists adicionado_pelo_responsavel boolean not null default false;

alter table public.convites
  add column if not exists criancas_adicionais_limite integer not null default 0
    check (criancas_adicionais_limite between 0 and 20);

create table if not exists public.configuracao_evento (
  id boolean primary key default true check (id),
  idade_limite_crianca smallint not null default 8
    check (idade_limite_crianca between 0 and 17),
  atualizado_em timestamptz not null default now()
);
insert into public.configuracao_evento(id) values(true) on conflict do nothing;

create table if not exists public.mensagens_organizacao (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  pessoa_solicitante text not null,
  pessoa_solicitada text not null,
  idade smallint not null,
  mensagem text not null,
  criado_em timestamptz not null default now()
);

alter table public.configuracao_evento enable row level security;
alter table public.mensagens_organizacao enable row level security;
revoke all on public.configuracao_evento, public.mensagens_organizacao from anon, authenticated;

create or replace function public.fim_do_dia_bahia(p_data date)
returns timestamptz language sql immutable as $$
  select (p_data::timestamp + time '23:59:59') at time zone 'America/Bahia'
$$;

create or replace function public.prazo_padrao_convite()
returns timestamptz language sql stable as $$
  select public.fim_do_dia_bahia((now() at time zone 'America/Bahia')::date + 7)
$$;

alter table public.convites alter column expira_em set default public.prazo_padrao_convite();

create or replace function public.administrar_status_convite(
  p_token_hash text, p_convidado_id uuid, p_status text
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_expirado boolean;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
  ) then return false; end if;
  select c.id, (not c.sem_expiracao and c.expira_em<=now())
  into v_convite_id,v_expirado
  from public.convidados g join public.convites c on c.id=g.convite_id
  where g.id=p_convidado_id;
  if v_convite_id is null then return false; end if;
  if p_status='aguardando' then
    delete from public.confirmacoes where convidado_id=p_convidado_id;
    if v_expirado then
      update public.convites set expira_em=public.prazo_padrao_convite(),
        sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
    end if;
  elsif p_status='confirmado' then
    insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
    values(v_convite_id,p_convidado_id,'sim',now())
    on conflict(convite_id,convidado_id) do update set status='sim',atualizado_em=now();
  elsif p_status='expirado' then
    update public.convites set expira_em=now()-interval '1 second',
      sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
  else return false; end if;
  return true;
end $$;

create or replace function public.configurar_idade_crianca(
  p_token_hash text, p_idade smallint
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_idade not between 0 and 17 or not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;
  update public.configuracao_evento set idade_limite_crianca=p_idade,atualizado_em=now() where id=true;
  update public.convidados set crianca=false
  where idade_confirmada is not null and idade_confirmada>p_idade;
  return true;
end $$;

create or replace function public.definir_convidado_crianca(
  p_token_hash text, p_convidado_id uuid, p_crianca boolean
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo) then return false; end if;
  update public.convidados set crianca=p_crianca,
    idade_confirmada=case when p_crianca then idade_confirmada else null end
  where id=p_convidado_id;
  return found;
end $$;

create or replace function public.configurar_criancas_grupo(
  p_token_hash text, p_codigo text, p_limite integer
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_limite not between 0 and 20 or not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;
  update public.convites set criancas_adicionais_limite=p_limite,atualizado_em=now()
  where codigo=upper(trim(p_codigo));
  return found;
end $$;

create or replace function public.adicionar_crianca_grupo(
  p_codigo text, p_nome text, p_idade smallint, p_solicitante text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype; v_limite smallint; v_usadas integer; v_codigo text; v_id uuid;
begin
  select c.* into v_convite from public.convites c
  where c.id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and c.ativo and (c.sem_expiracao or c.expira_em>now());
  if not found or length(trim(p_nome))<2 or length(trim(p_solicitante))<2 or p_idade<0 then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
  end if;
  if not exists(select 1 from public.convidados where convite_id=v_convite.id and pode_gerenciar and nome=trim(p_solicitante)) then
    return jsonb_build_object('ok',false,'motivo','sem_permissao');
  end if;
  if p_idade>=18 then
    insert into public.mensagens_organizacao(convite_id,pessoa_solicitante,pessoa_solicitada,idade,mensagem)
    values(v_convite.id,trim(p_solicitante),trim(p_nome),p_idade,
      'Grupo familiar: '||v_convite.nome_familia||'. '||trim(p_solicitante)||
      ' tentou adicionar '||trim(p_nome)||', '||p_idade||' anos. Solicita inclusão como adulto.');
    return jsonb_build_object('ok',false,'motivo','adulto_notificado');
  end if;
  select count(*) into v_usadas from public.convidados
  where convite_id=v_convite.id and adicionado_pelo_responsavel;
  if v_usadas>=v_convite.criancas_adicionais_limite then
    return jsonb_build_object('ok',false,'motivo','limite_atingido');
  end if;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  loop
    v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
    exit when not exists(select 1 from public.convidados where codigo_individual=v_codigo)
      and not exists(select 1 from public.convites where codigo=v_codigo)
      and not exists(select 1 from public.organizacao where codigo=v_codigo);
  end loop;
  insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,codigo_individual,
    crianca,idade_confirmada,adicionado_pelo_responsavel)
  values(v_convite.id,trim(p_nome),false,false,
    coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite.id),1),
    v_codigo,p_idade<=v_limite,p_idade,true) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id,'crianca',p_idade<=v_limite,
    'restantes',v_convite.criancas_adicionais_limite-v_usadas-1);
end $$;

create or replace function public.administrar_expiracao(
  p_token_hash text, p_convite_id uuid, p_acao text, p_data timestamptz default null
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo) then return false; end if;
  if p_acao='resetar_7_dias' then
    update public.convites set expira_em=public.prazo_padrao_convite(),sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='definir_data' and p_data is not null then
    update public.convites set expira_em=p_data,sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='expirar' then
    update public.convites set expira_em=now()-interval '1 second',sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='retirar_expiracao' then
    update public.convites set expira_em=null,sem_expiracao=true,atualizado_em=now() where id=p_convite_id;
  else return false; end if;
  return found;
end $$;

revoke all on function public.administrar_status_convite(text,uuid,text) from public;
revoke all on function public.configurar_idade_crianca(text,smallint) from public;
revoke all on function public.adicionar_crianca_grupo(text,text,smallint,text) from public;
grant execute on function public.administrar_status_convite(text,uuid,text) to anon,authenticated;
grant execute on function public.configurar_idade_crianca(text,smallint) to anon,authenticated;
grant execute on function public.adicionar_crianca_grupo(text,text,smallint,text) to anon,authenticated;
grant execute on function public.definir_convidado_crianca(text,uuid,boolean) to anon,authenticated;
grant execute on function public.configurar_criancas_grupo(text,text,integer) to anon,authenticated;

create or replace function public.salvar_confirmacao(
  p_codigo text, p_respostas jsonb, p_mensagem text default null
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_item jsonb; v_id uuid; v_status text; v_idade smallint; v_limite smallint;
begin
  select c.id into v_convite_id from public.convites c where c.id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and c.ativo and (c.sem_expiracao or c.expira_em>now());
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  if v_convite_id is null or jsonb_typeof(p_respostas)<>'array' then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_id=(v_item->>'convidado_id')::uuid; v_status=v_item->>'status';
    if v_status not in ('sim','nao') or not exists(select 1 from public.convidados where id=v_id and convite_id=v_convite_id) then return false; end if;
    if v_status='sim' and exists(select 1 from public.convidados where id=v_id and crianca) then
      v_idade=(v_item->>'idade')::smallint;
      if v_idade is null or v_idade not between 0 and 17 then return false; end if;
      update public.convidados set idade_confirmada=v_idade,crianca=(v_idade<=v_limite) where id=v_id;
    end if;
    insert into public.confirmacoes(convite_id,convidado_id,status,mensagem,atualizado_em)
    values(v_convite_id,v_id,v_status,nullif(trim(p_mensagem),''),now())
    on conflict(convite_id,convidado_id) do update set status=excluded.status,mensagem=excluded.mensagem,atualizado_em=now();
  end loop;
  return true;
exception when invalid_text_representation then return false;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org public.organizacao%rowtype; v_perfil text;
begin
  select o.* into v_org from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;
  if not found then return null; end if;
  v_perfil=case when v_org.administrador then 'admin' when v_org.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end;
  return jsonb_build_object(
    'perfil',v_perfil,'conta',jsonb_build_object('id',v_org.id,'nome',v_org.nome,'usuario',v_org.usuario,'funcao',v_org.funcao,'principal',v_org.principal,'exige_troca_senha',v_org.exige_troca_senha),
    'idade_limite_crianca',(select idade_limite_crianca from public.configuracao_evento where id=true),
    'convidados_total',(select count(*) from public.convidados),
    'confirmados',(select count(*) from public.confirmacoes where status='sim'),
    'nao_comparecem',(select count(*) from public.confirmacoes where status='nao'),
    'aguardando',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where not exists(select 1 from public.confirmacoes cf where cf.convidado_id=g.id) and (c.sem_expiracao or c.expira_em>now())),
    'presentes_assinados',case when v_perfil='assessoria' then 0 else (select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado') end,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'convite_id',c.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',case when not c.sem_expiracao and c.expira_em<=now() and cf.id is null then 'expirado' when cf.status is not null then 'confirmado' else 'aguardando' end,
      'resposta',cf.status,'crianca',g.crianca,'idade',g.idade_confirmada,
      'codigo',c.codigo,'codigo_individual',g.codigo_individual,'conjunto',c.nome_familia,'funcao',g.funcao,
      'nivel_acesso',c.nivel_acesso,'protegido',false,'expira_em',c.expira_em,'sem_expiracao',c.sem_expiracao,
      'expirado',(not c.sem_expiracao and c.expira_em<=now())
    ) order by c.nome_familia,g.ordem,g.nome) from public.convidados g join public.convites c on c.id=g.convite_id
      left join public.confirmacoes cf on cf.convidado_id=g.id),'[]'::jsonb),
    'organizacao',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'nome',o.nome,'usuario',o.usuario,'codigo',o.codigo,'funcao',o.funcao,'administrador',o.administrador,'principal',o.principal,'senha_criada',o.senha_hash is not null,'exige_troca_senha',o.exige_troca_senha) order by o.principal desc,o.nome) from public.organizacao o where o.ativo),'[]'::jsonb),
    'grupos',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object(
      'id',c.id,'codigo',c.codigo,'titulo',c.nome_familia,'total',(select count(*) from public.convidados g where g.convite_id=c.id),
      'protegido',false,'criancas_adicionais_limite',c.criancas_adicionais_limite,
      'criancas_adicionais_usadas',(select count(*) from public.convidados g where g.convite_id=c.id and g.adicionado_pelo_responsavel)
    ) order by c.nome_familia) from public.convites c where c.ativo),'[]'::jsonb) end,
    'mensagens',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(x order by x.atualizado_em desc) from (
        select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em
        from public.confirmacoes cf join public.convites c on c.id=cf.convite_id
        where nullif(trim(cf.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,cf.mensagem
        union all
        select c.nome_familia,c.codigo,m.mensagem,m.criado_em from public.mensagens_organizacao m join public.convites c on c.id=m.convite_id
      )x),'[]'::jsonb) end,
    'reservas',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'convidado',c.nome_familia,'codigo',c.codigo,'presente',p.nome,'quantidade',r.quantidade,'criado_em',r.criado_em) order by r.criado_em desc) from public.reservas_presentes r join public.convites c on c.id=r.convite_id join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb) end,
    'ultimas_confirmacoes','[]'::jsonb
  );
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype; v_org public.organizacao%rowtype; v_limite smallint;
begin
  select * into v_org from public.organizacao where codigo=upper(trim(p_codigo)) and ativo;
  if found then return jsonb_build_object(
    'codigo',v_org.codigo,'codigo_conjunto',v_org.codigo,'nome_familia',v_org.nome,'funcao_cortejo',v_org.funcao,
    'instrucoes_cortejo','[]'::jsonb,'convidados','[]'::jsonb,'nivel_acesso',3,
    'perfil_acesso',case when v_org.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end,
    'manuais','[]'::jsonb,'senha_criada',v_org.senha_hash is not null,'exige_troca_senha',v_org.exige_troca_senha,
    'pode_gerenciar',true,'responsaveis','[]'::jsonb,'expira_em',null,'expirado',false,'sem_expiracao',true,
    'idade_limite_crianca',8,'criancas_adicionais_restantes',0
  ); end if;
  select * into v_convite from public.convites where id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and ativo;
  if not found then return null; end if;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  return jsonb_build_object(
    'codigo',upper(trim(p_codigo)),'codigo_conjunto',v_convite.codigo,'nome_familia',v_convite.nome_familia,
    'funcao_cortejo',v_convite.funcao_cortejo,'instrucoes_cortejo',v_convite.instrucoes_cortejo,
    'nivel_acesso',v_convite.nivel_acesso,'perfil_acesso','convidado',
    'manuais',to_jsonb(coalesce(v_convite.manuais,'{}'::text[])),'senha_criada',false,'exige_troca_senha',false,
    'expira_em',v_convite.expira_em,'sem_expiracao',v_convite.sem_expiracao,
    'expirado',(not v_convite.sem_expiracao and v_convite.expira_em<=now()),
    'idade_limite_crianca',v_limite,
    'criancas_adicionais_restantes',greatest(v_convite.criancas_adicionais_limite-
      (select count(*) from public.convidados where convite_id=v_convite.id and adicionado_pelo_responsavel),0),
    'pode_gerenciar',coalesce((select pode_gerenciar from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),false),
    'responsaveis',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'nome',g.nome,'funcao',g.funcao))
      from public.convidados g where g.convite_id=v_convite.id and g.pode_gerenciar),'[]'::jsonb),
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'codigo_individual',g.codigo_individual,'pode_gerenciar',g.pode_gerenciar,
      'funcao',g.funcao,'status',cf.status,'crianca',g.crianca,'idade',g.idade_confirmada
    ) order by g.ordem,g.nome) from public.convidados g left join public.confirmacoes cf on cf.convidado_id=g.id
      where g.convite_id=v_convite.id),'[]'::jsonb)
  );
end $$;

grant execute on function public.salvar_confirmacao(text,jsonb,text),public.dashboard_noivos(text),public.buscar_convite(text) to anon,authenticated;
notify pgrst, 'reload schema';

-- ============================================================================
-- migration_019_confirmados_local_notificacoes.sql
-- ============================================================================
-- Confirmações após o prazo, notificações e dados editáveis do evento.

alter table public.configuracao_evento
  add column if not exists data_evento date not null default date '2026-10-03',
  add column if not exists hora_evento time not null default time '18:30',
  add column if not exists cidade text not null default 'Candeias-BA',
  add column if not exists local_liberado boolean not null default false,
  add column if not exists nome_espaco text not null default 'Espaço Brunus',
  add column if not exists endereco text not null
    default 'Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000',
  add column if not exists link_maps text;

create table if not exists public.notificacoes_organizacao (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  convidado_id uuid references public.convidados(id) on delete set null,
  tipo text not null default 'alteracao_status',
  status_anterior text,
  status_novo text not null,
  mensagem text not null,
  criado_em timestamptz not null default now()
);

alter table public.notificacoes_organizacao enable row level security;
revoke all on public.notificacoes_organizacao from anon, authenticated;

create or replace function public.registrar_notificacao_status(
  p_convite_id uuid,
  p_convidado_id uuid,
  p_anterior text,
  p_novo text,
  p_origem text
) returns void
language plpgsql security definer set search_path=public as $$
declare v_nome text; v_grupo text;
begin
  if p_anterior is not distinct from p_novo then return; end if;
  select g.nome,c.nome_familia into v_nome,v_grupo
  from public.convidados g join public.convites c on c.id=g.convite_id
  where g.id=p_convidado_id and c.id=p_convite_id;
  insert into public.notificacoes_organizacao(
    convite_id,convidado_id,status_anterior,status_novo,mensagem
  ) values(
    p_convite_id,p_convidado_id,p_anterior,p_novo,
    coalesce(v_nome,'Convidado')||' ('||coalesce(v_grupo,'grupo')||') alterou o status de '||
    coalesce(p_anterior,'aguardando')||' para '||p_novo||' via '||p_origem||'.'
  );
end $$;

create or replace function public.administrar_configuracao_evento(
  p_token_hash text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_link text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;
  v_link=nullif(trim(coalesce(p_dados->>'link_maps','')),'');
  if length(trim(coalesce(p_dados->>'cidade','')))<2
    or length(trim(coalesce(p_dados->>'nome_espaco','')))<2
    or length(trim(coalesce(p_dados->>'endereco','')))<5
    or (v_link is not null and v_link !~* '^https?://') then return false; end if;
  update public.configuracao_evento set
    data_evento=(p_dados->>'data')::date,
    hora_evento=(p_dados->>'hora')::time,
    cidade=trim(p_dados->>'cidade'),
    local_liberado=coalesce((p_dados->>'local_liberado')::boolean,false),
    nome_espaco=trim(p_dados->>'nome_espaco'),
    endereco=trim(p_dados->>'endereco'),
    link_maps=v_link,
    atualizado_em=now()
  where id=true;
  return found;
exception when invalid_text_representation or datetime_field_overflow then
  return false;
end $$;

create or replace function public.administrar_status_convite(
  p_token_hash text, p_convidado_id uuid, p_status text
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_expirado boolean; v_anterior text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
  ) then return false; end if;
  select c.id,(not c.sem_expiracao and c.expira_em<=now()),cf.status
  into v_convite_id,v_expirado,v_anterior
  from public.convidados g join public.convites c on c.id=g.convite_id
  left join public.confirmacoes cf on cf.convidado_id=g.id
  where g.id=p_convidado_id;
  if v_convite_id is null then return false; end if;
  if p_status='aguardando' then
    delete from public.confirmacoes where convidado_id=p_convidado_id;
    if v_expirado then
      update public.convites set expira_em=public.prazo_padrao_convite(),
        sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
    end if;
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'aguardando','dashboard');
  elsif p_status='confirmado' then
    insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
    values(v_convite_id,p_convidado_id,'sim',now())
    on conflict(convite_id,convidado_id) do update set status='sim',atualizado_em=now();
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'sim','dashboard');
  elsif p_status='expirado' then
    delete from public.confirmacoes where convidado_id=p_convidado_id;
    update public.convites set expira_em=now()-interval '1 second',
      sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'expirado','dashboard');
  else return false; end if;
  return true;
end $$;

create or replace function public.salvar_confirmacao(
  p_codigo text, p_respostas jsonb, p_mensagem text default null
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_convite_id uuid; v_item jsonb; v_id uuid; v_status text; v_anterior text;
  v_idade smallint; v_limite smallint; v_prazo_vencido boolean; v_tinha_confirmado boolean;
begin
  select c.id,(not c.sem_expiracao and c.expira_em<=now()),
    exists(select 1 from public.confirmacoes cf where cf.convite_id=c.id and cf.status='sim')
  into v_convite_id,v_prazo_vencido,v_tinha_confirmado
  from public.convites c where c.id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and c.ativo;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  if v_convite_id is null or jsonb_typeof(p_respostas)<>'array'
    or (v_prazo_vencido and not v_tinha_confirmado) then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_id=(v_item->>'convidado_id')::uuid; v_status=v_item->>'status';
    if v_status not in ('sim','nao') or not exists(
      select 1 from public.convidados where id=v_id and convite_id=v_convite_id
    ) then return false; end if;
    select status into v_anterior from public.confirmacoes where convidado_id=v_id;
    if v_status='sim' and exists(select 1 from public.convidados where id=v_id and crianca) then
      v_idade=(v_item->>'idade')::smallint;
      if v_idade is null or v_idade not between 0 and 17 then return false; end if;
      update public.convidados set idade_confirmada=v_idade,crianca=(v_idade<=v_limite) where id=v_id;
    end if;
    insert into public.confirmacoes(convite_id,convidado_id,status,mensagem,atualizado_em)
    values(v_convite_id,v_id,v_status,nullif(trim(p_mensagem),''),now())
    on conflict(convite_id,convidado_id) do update set
      status=excluded.status,mensagem=excluded.mensagem,atualizado_em=now();
    perform public.registrar_notificacao_status(v_convite_id,v_id,v_anterior,v_status,'convite');
  end loop;
  if v_prazo_vencido and not exists(
    select 1 from public.confirmacoes where convite_id=v_convite_id and status='sim'
  ) then
    delete from public.confirmacoes where convite_id=v_convite_id;
  end if;
  return true;
exception when invalid_text_representation then return false;
end $$;

-- Reaplica as funções de leitura com as novas regras sem duplicar a estrutura.
create or replace function public.evento_publico()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'data',to_char(data_evento,'YYYY-MM-DD'),
    'hora',to_char(hora_evento,'HH24:MI'),
    'cidade',cidade,
    'local_liberado',local_liberado,
    'nome_espaco',nome_espaco,
    'endereco',endereco,
    'link_maps',link_maps
  ) from public.configuracao_evento where id=true
$$;

-- Acrescenta notificações às mensagens retornadas pelo painel.
-- As funções completas de dashboard e busca da migração 018 são substituídas
-- abaixo por wrappers que enriquecem o JSON produzido pelas versões internas.
alter function public.dashboard_noivos(text) rename to dashboard_noivos_018;
alter function public.buscar_convite(text) rename to buscar_convite_018;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'evento',public.evento_publico(),
      'convidados',coalesce((
        select jsonb_agg(
          item || jsonb_build_object(
            'status',case
              when coalesce((item->>'expirado')::boolean,false)
                and coalesce(item->>'resposta','')<>'sim' then 'expirado'
              else item->>'status'
            end,
            'expirado',coalesce((item->>'expirado')::boolean,false)
              and coalesce(item->>'resposta','')<>'sim'
          )
        )
        from jsonb_array_elements(coalesce(base->'convidados','[]'::jsonb)) item
      ),'[]'::jsonb),
      'mensagens',coalesce(base->'mensagens','[]'::jsonb) || coalesce((
        select jsonb_agg(jsonb_build_object(
          'grupo',c.nome_familia,'codigo',c.codigo,'mensagem',n.mensagem,'atualizado_em',n.criado_em
        ) order by n.criado_em desc)
        from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id
      ),'[]'::jsonb)
    ) end
  from (select public.dashboard_noivos_018(p_token_hash) base) x
$$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'evento',public.evento_publico(),
      'prazo_vencido',coalesce((base->>'expirado')::boolean,false),
      'expirado',coalesce((base->>'expirado')::boolean,false)
        and not exists(
          select 1 from public.confirmacoes cf
          join public.convidados g on g.id=cf.convidado_id
          where g.convite_id=(
            select c.id from public.convites c where c.id=coalesce(
              (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
              (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
            )
          ) and cf.status='sim'
        )
    ) end
  from (select public.buscar_convite_018(p_codigo) base) x
$$;

revoke all on function public.administrar_configuracao_evento(text,jsonb) from public;
grant execute on function public.administrar_configuracao_evento(text,jsonb),
  public.dashboard_noivos(text),public.buscar_convite(text),
  public.salvar_confirmacao(text,jsonb,text) to anon,authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- migration_020_categorias_configuracoes_convites.sql
-- ============================================================================
-- Categorias editáveis, configurações gerais, URLs dos convites e suporte à exportação.

create table if not exists public.categorias_presentes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  ordem integer not null default 0,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);


alter table public.presentes
  add column if not exists categoria_id uuid references public.categorias_presentes(id);

create table if not exists public.configuracoes_convites (
  id boolean primary key default true check (id),
  url_base text not null default 'https://gabriel-alanna-casamento.rexmeil.chatgpt.site',
  titulo_site text not null default 'O Que Deus Uniu',
  mensagem_confirmacao text not null default 'Acesse pelo QR Code, informe seu código e confirme a presença.',
  dias_expiracao_padrao integer not null default 7 check (dias_expiracao_padrao between 1 and 365),
  atualizado_em timestamptz not null default now()
);

insert into public.configuracoes_convites (id) values (true)
on conflict (id) do nothing;

create or replace function public.tem_acesso_lista(p_token_hash text)
returns boolean language sql security definer set search_path=public stable as $$
  select exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva','assessoria'))
  );
$$;

create or replace function public.configuracoes_convites_dashboard(p_token_hash text)
returns jsonb language sql security definer set search_path=public stable as $$
  select case when public.tem_acesso_lista(p_token_hash) then
    (select to_jsonb(c)-'id'-'atualizado_em' from public.configuracoes_convites c where c.id)
  else null end;
$$;

create or replace function public.listar_categorias_presentes_dashboard(p_token_hash text)
returns jsonb language sql security definer set search_path=public stable as $$
  select case when public.tem_acesso_lista(p_token_hash) then
    coalesce((select jsonb_agg(to_jsonb(c) order by c.ordem,c.nome) from public.categorias_presentes c where c.ativo),'[]'::jsonb)
  else null end;
$$;

create or replace function public.administrar_configuracoes_convites(
  p_token_hash text, p_acao text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_admin boolean;
  v_lista boolean;
  v_ordem integer;
begin
  v_lista := public.tem_acesso_lista(p_token_hash);
  select exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and o.administrador
  ) into v_admin;

  if p_acao='categoria_presente' and v_lista then
    update public.presentes set categoria_id=nullif(p_dados->>'categoria_id','')::uuid
    where id=(p_dados->>'presente_id')::uuid;
    return found;
  end if;
  if not v_admin then return false; end if;

  if p_acao='gerais' then
    update public.configuracoes_convites set
      url_base=rtrim(trim(p_dados->>'url_base'),'/'),
      titulo_site=left(trim(p_dados->>'titulo_site'),120),
      mensagem_confirmacao=left(trim(p_dados->>'mensagem_confirmacao'),500),
      dias_expiracao_padrao=greatest(1,least(365,(p_dados->>'dias_expiracao_padrao')::integer)),
      atualizado_em=now()
    where id;
    return found;
  elsif p_acao='criar_categoria' then
    select coalesce(max(ordem),0)+1 into v_ordem from public.categorias_presentes;
    insert into public.categorias_presentes(nome,ordem) values(left(trim(p_dados->>'nome'),80),v_ordem);
  elsif p_acao='editar_categoria' then
    update public.categorias_presentes set nome=left(trim(p_dados->>'nome'),80) where id=(p_dados->>'id')::uuid;
  elsif p_acao='desativar_categoria' then
    update public.presentes set categoria_id=null where categoria_id=(p_dados->>'id')::uuid;
    update public.categorias_presentes set ativo=false where id=(p_dados->>'id')::uuid;
  elsif p_acao='mover_categoria' then
    update public.categorias_presentes set ordem=ordem+((p_dados->>'direcao')::integer) where id=(p_dados->>'id')::uuid;
  else return false;
  end if;
  return true;
exception when unique_violation or invalid_text_representation or not_null_violation then return false;
end; $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'nome',p.nome,'descricao',p.descricao,'imagens',coalesce(p.imagens,'{}'),
    'categoria_id',p.categoria_id,'categoria',c.nome,'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',greatest(p.quantidade_total-coalesce(r.assinada,0),0)
  ) order by c.ordem nulls last,p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join public.categorias_presentes c on c.id=p.categoria_id and c.ativo
  left join (
    select presente_id,sum(quantidade)::integer assinada from public.reservas_presentes
    where status='confirmado' group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo;
$$;

revoke all on function public.tem_acesso_lista(text) from public;
revoke all on function public.configuracoes_convites_dashboard(text) from public;
revoke all on function public.listar_categorias_presentes_dashboard(text) from public;
revoke all on function public.administrar_configuracoes_convites(text,text,jsonb) from public;
grant execute on function public.configuracoes_convites_dashboard(text) to anon,authenticated;
grant execute on function public.listar_categorias_presentes_dashboard(text) to anon,authenticated;
grant execute on function public.administrar_configuracoes_convites(text,text,jsonb) to anon,authenticated;
grant execute on function public.listar_presentes() to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_021_origem_duplicidades.sql
-- ============================================================================
-- Classificação da origem dos convidados e suporte à importação revisada.

alter table public.convidados
  add column if not exists origem text not null default 'nao_classificado';

alter table public.convidados drop constraint if exists convidados_origem_check;
alter table public.convidados add constraint convidados_origem_check
  check (origem in ('noivo','noiva','ambos','nao_classificado'));

create or replace function public.administrar_origem_convidado(
  p_token_hash text,p_convidado_id uuid,p_origem text
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_origem not in ('noivo','noiva','ambos','nao_classificado') or not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;
  update public.convidados set origem=p_origem where id=p_convidado_id;
  return found;
end $$;

do $$ begin
  if to_regprocedure('public.administrar_convidados_020(text,text,jsonb)') is null then
    alter function public.administrar_convidados(text,text,jsonb) rename to administrar_convidados_020;
  end if;
end $$;

create or replace function public.administrar_convidados(p_token_hash text,p_acao text,p_dados jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_ok boolean;v_id uuid;v_origem text;
begin
  v_ok:=public.administrar_convidados_020(p_token_hash,p_acao,p_dados);
  if not v_ok then return false; end if;
  if p_acao in ('adicionar','editar') then
    v_origem:=coalesce(p_dados->>'origem','nao_classificado');
    if v_origem not in ('noivo','noiva','ambos','nao_classificado') then return false; end if;
    v_id:=nullif(p_dados->>'id','')::uuid;
    if v_id is null then
      select g.id into v_id from public.convidados g
      where lower(trim(g.nome))=lower(trim(p_dados->>'nome')) order by g.criado_em desc limit 1;
    end if;
    update public.convidados set origem=v_origem where id=v_id;
  end if;
  return true;
end $$;

create or replace function public.importar_convidados_automatico(p_token_hash text,p_linhas jsonb)
returns integer language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_codigo text;v_nome text;v_funcao text;v_origem text;v_convite_id uuid;v_total integer:=0;
begin
  if not exists(select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and (o.administrador or o.funcao in ('noivo','noiva'))) then return -1; end if;
  if jsonb_typeof(p_linhas)<>'array' or jsonb_array_length(p_linhas)<1 or jsonb_array_length(p_linhas)>1000 then return -2; end if;
  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(coalesce(v_item->>'nome',''));v_funcao:=nullif(trim(coalesce(v_item->>'funcao','')),'');v_origem:=coalesce(v_item->>'origem','nao_classificado');
    if length(v_nome)<2 or length(v_nome)>150 or v_origem not in ('noivo','noiva','ambos','nao_classificado') then return -2; end if;
    loop v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));exit when not exists(select 1 from public.convites where codigo=v_codigo) and not exists(select 1 from public.convidados where codigo_individual=v_codigo);end loop;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo) values(v_codigo,v_nome,1,'convidado',true) returning id into v_convite_id;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem) values(v_convite_id,v_nome,false,true,1,v_funcao,v_codigo,v_origem);
    v_total:=v_total+1;
  end loop;
  return v_total;
exception when unique_violation or invalid_text_representation or not_null_violation then return -2;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else base || jsonb_build_object(
    'evento',public.evento_publico(),
    'convidados',coalesce((select jsonb_agg(item || jsonb_build_object(
      'status',case when coalesce((item->>'expirado')::boolean,false) and coalesce(item->>'resposta','')<>'sim' then 'expirado' else item->>'status' end,
      'expirado',coalesce((item->>'expirado')::boolean,false) and coalesce(item->>'resposta','')<>'sim',
      'origem',coalesce((select g.origem from public.convidados g where g.id=(item->>'id')::uuid),'nao_classificado')
    )) from jsonb_array_elements(coalesce(base->'convidados','[]'::jsonb)) item),'[]'::jsonb),
    'mensagens',coalesce(base->'mensagens','[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('grupo',c.nome_familia,'codigo',c.codigo,'mensagem',n.mensagem,'atualizado_em',n.criado_em) order by n.criado_em desc) from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id),'[]'::jsonb)
  ) end from (select public.dashboard_noivos_018(p_token_hash) base) x
$$;

revoke all on function public.administrar_origem_convidado(text,uuid,text),public.administrar_convidados(text,text,jsonb),public.importar_convidados_automatico(text,jsonb) from public;
grant execute on function public.administrar_origem_convidado(text,uuid,text),public.administrar_convidados(text,text,jsonb),public.importar_convidados_automatico(text,jsonb),public.dashboard_noivos(text) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_022_mercado_pago_presentes.sql
-- ============================================================================
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

-- Código personalizado de convidados (incorpora migration_031)
create or replace function public.administrar_convidado_com_codigo(
  p_token_hash text, p_acao text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo_individual','')));
  v_nome text := trim(coalesce(p_dados->>'nome',''));
  v_funcao text := nullif(trim(coalesce(p_dados->>'funcao','')),'');
  v_origem text := coalesce(p_dados->>'origem','nao_classificado');
  v_id uuid; v_convite_id uuid; v_convite_atual uuid; v_convite_destino uuid; v_codigo_antigo text; v_grupo_individual boolean := false;
begin
  if p_acao not in ('adicionar_com_codigo','editar_com_codigo') or v_codigo !~ '^[A-Z0-9]{6}$'
    or length(v_nome) not between 2 and 150 or v_origem not in ('noivo','noiva','ambos','nao_classificado')
    or not exists(select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
      where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and (o.administrador or o.funcao in ('noivo','noiva')))
    then return false; end if;
  perform pg_advisory_xact_lock(hashtext(v_codigo));
  if p_acao='adicionar_com_codigo' then
    if exists(select 1 from public.convites where codigo=v_codigo) or exists(select 1 from public.convidados where codigo_individual=v_codigo)
      or exists(select 1 from public.organizacao where codigo=v_codigo) then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo) values(v_codigo,v_nome,1,'convidado',true) returning id into v_convite_id;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem,crianca)
      values(v_convite_id,v_nome,false,true,1,v_funcao,v_codigo,v_origem,coalesce((p_dados->>'crianca')::boolean,false));
    return true;
  end if;
  v_id:=nullif(p_dados->>'id','')::uuid;
  select g.convite_id,g.codigo_individual,(c.codigo=g.codigo_individual) into v_convite_atual,v_codigo_antigo,v_grupo_individual
    from public.convidados g join public.convites c on c.id=g.convite_id where g.id=v_id;
  if v_id is null or v_convite_atual is null or exists(select 1 from public.convites where codigo=v_codigo and id<>v_convite_atual) or exists(select 1 from public.organizacao where codigo=v_codigo)
    or exists(select 1 from public.convidados where codigo_individual=v_codigo and id<>v_id) then return false; end if;
  select id into v_convite_destino from public.convites where codigo=upper(trim(p_dados->>'codigo'));
  if v_convite_destino is null then return false; end if;
  update public.confirmacoes set convite_id=v_convite_destino where convidado_id=v_id;
  update public.convidados set convite_id=v_convite_destino,nome=v_nome,principal=false,
    pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),funcao=v_funcao,
    codigo_individual=v_codigo,origem=v_origem,crianca=coalesce((p_dados->>'crianca')::boolean,crianca) where id=v_id;
  if v_grupo_individual and v_convite_atual=v_convite_destino then
    update public.convites set codigo=v_codigo where id=v_convite_atual and codigo=v_codigo_antigo;
  elsif v_grupo_individual then
    delete from public.convites c where c.id=v_convite_atual and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
  end if;
  return found;
exception when unique_violation or invalid_text_representation or not_null_violation then return false;
end $$;
revoke all on function public.administrar_convidado_com_codigo(text,text,jsonb) from public;
grant execute on function public.administrar_convidado_com_codigo(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

-- ============================================================================
-- migration_023_painel_pagamentos_reembolsos.sql
-- ============================================================================
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

-- ============================================================================
-- migration_024_cpf_pagamentos.sql
-- ============================================================================
begin;

alter table public.integracoes_pagamento
  add column if not exists recolher_cpf boolean not null default false,
  add column if not exists cpf_valor_minimo_centavos integer not null default 35000;

alter table public.integracoes_pagamento
  drop constraint if exists integracoes_pagamento_cpf_minimo_check;

alter table public.integracoes_pagamento
  add constraint integracoes_pagamento_cpf_minimo_check
  check (cpf_valor_minimo_centavos between 1 and 100000000);

alter table public.reservas_presentes
  add column if not exists doador_chave text,
  add column if not exists cpf_cifrado text,
  add column if not exists cpf_consentimento_em timestamptz,
  add column if not exists cpf_politica_versao text;

-- Permite que pagamentos aprovados anteriores à migração também participem
-- do total acumulado do convite.
update public.reservas_presentes
set doador_chave = 'convite:' || convite_id::text
where meio = 'mercado_pago'
  and doador_chave is null;

create index if not exists reservas_doador_pagamentos_idx
  on public.reservas_presentes (doador_chave, status, meio)
  where meio = 'mercado_pago';

comment on column public.reservas_presentes.cpf_cifrado is
  'CPF criptografado pela aplicação; nunca armazenar em texto simples.';

alter table public.integracoes_pagamento enable row level security;
alter table public.reservas_presentes enable row level security;

notify pgrst, 'reload schema';

commit;

-- ============================================================================
-- migration_025_importacao_excel_grupos_presentes.sql
-- ============================================================================
begin;

create or replace function public.importar_convidados_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb; v_codigo text; v_codigo_individual text; v_nome text;
  v_grupo text; v_funcao text; v_origem text; v_convite_id uuid;
  v_ordem integer; v_total integer := 0;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) not between 1 and 1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_grupo := nullif(trim(coalesce(v_item->>'grupo','')), '');
    v_funcao := nullif(trim(coalesce(v_item->>'funcao','')), '');
    v_origem := coalesce(v_item->>'origem','nao_classificado');
    if length(v_nome) < 2 or length(v_nome) > 150 or v_origem not in ('noivo','noiva','ambos','nao_classificado') then return -2; end if;

    v_convite_id := null;
    if v_grupo is not null then
      select id into v_convite_id from public.convites
      where ativo and lower(trim(nome_familia)) = lower(v_grupo)
      order by criado_em limit 1;
    end if;
    if v_convite_id is null then
      loop
        v_codigo := upper(substr(md5(gen_random_uuid()::text),1,6));
        exit when not exists(select 1 from public.convites where codigo=v_codigo)
          and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
      end loop;
      insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
      values(v_codigo,coalesce(v_grupo,v_nome),1,'convidado',true) returning id into v_convite_id;
    end if;

    loop
      v_codigo_individual := upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo_individual)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo_individual);
    end loop;
    select coalesce(max(ordem),0)+1 into v_ordem from public.convidados where convite_id=v_convite_id;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem)
    values(v_convite_id,v_nome,v_ordem=1,v_ordem=1,v_ordem,v_funcao,v_codigo_individual,v_origem);
    v_total := v_total + 1;
  end loop;
  return v_total;
exception when unique_violation or invalid_text_representation or not_null_violation then return -2;
end $$;

create or replace function public.importar_presentes_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb; v_nome text; v_categoria text; v_categoria_id uuid;
  v_descricao text; v_imagens text[]; v_valor numeric; v_quantidade integer;
  v_ordem integer; v_total integer := 0;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) not between 1 and 1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_categoria := trim(coalesce(v_item->>'categoria',''));
    v_descricao := nullif(trim(coalesce(v_item->>'descricao','')), '');
    v_valor := (v_item->>'valor')::numeric;
    v_quantidade := greatest(1, least(10000, coalesce((v_item->>'quantidade')::integer,1)));
    select coalesce(array_agg(value), '{}') into v_imagens from jsonb_array_elements_text(coalesce(v_item->'links_fotos','[]'::jsonb));
    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2 or v_valor<0 or cardinality(v_imagens)>10 then return -2; end if;

    select id into v_categoria_id from public.categorias_presentes where lower(trim(nome))=lower(v_categoria) order by ativo desc, ordem limit 1;
    if v_categoria_id is null then
      select coalesce(max(ordem),0)+1 into v_ordem from public.categorias_presentes;
      insert into public.categorias_presentes(nome,ordem) values(v_categoria,v_ordem) returning id into v_categoria_id;
    else
      update public.categorias_presentes set ativo=true where id=v_categoria_id;
    end if;
    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens)
    values(v_nome,v_descricao,round(v_valor*100)::integer,v_quantidade,v_ordem,v_categoria_id,v_imagens);
    v_total := v_total + 1;
  end loop;
  return v_total;
exception when invalid_text_representation or numeric_value_out_of_range or not_null_violation then return -2;
end $$;

revoke all on function public.importar_convidados_automatico(text,jsonb) from public;
revoke all on function public.importar_presentes_automatico(text,jsonb) from public;
grant execute on function public.importar_convidados_automatico(text,jsonb) to anon,authenticated;
grant execute on function public.importar_presentes_automatico(text,jsonb) to anon,authenticated;

notify pgrst, 'reload schema';
commit;

-- ============================================================================
-- migration_026_controles_administrativos.sql
-- ============================================================================
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

-- ============================================================================
-- migration_027_auditoria_antes_depois.sql
-- ============================================================================
begin;

-- Remove informações que nunca devem ser copiadas para o histórico.
create or replace function public.sanitizar_dados_auditoria(valor jsonb)
returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare
  resultado jsonb := '{}'::jsonb;
  item record;
begin
  if valor is null then return null; end if;
  if jsonb_typeof(valor) <> 'object' then return valor; end if;

  for item in select key, value from jsonb_each(valor) loop
    if item.key ~* '(cpf|token|secret|segredo|senha|password|hash|authorization|access[_-]?key|public[_-]?key|client[_-]?id|client[_-]?secret|credencial|cifrado)' then
      resultado := resultado || jsonb_build_object(item.key, '[PROTEGIDO]');
    else
      resultado := resultado || jsonb_build_object(item.key, item.value);
    end if;
  end loop;
  return resultado;
end $$;

create or replace function public.registrar_auditoria_tabela()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_antes jsonb;
  v_depois jsonb;
  v_campos text[] := array[]::text[];
  v_chave text;
  v_id text;
begin
  v_antes := case when tg_op in ('UPDATE','DELETE') then public.sanitizar_dados_auditoria(to_jsonb(old)) else null end;
  v_depois := case when tg_op in ('INSERT','UPDATE') then public.sanitizar_dados_auditoria(to_jsonb(new)) else null end;
  v_id := coalesce(v_depois->>'id', v_antes->>'id', '');

  if tg_op = 'UPDATE' then
    for v_chave in
      select key from (
        select jsonb_object_keys(coalesce(v_antes, '{}'::jsonb)) as key
        union
        select jsonb_object_keys(coalesce(v_depois, '{}'::jsonb)) as key
      ) chaves
      where coalesce(v_antes->key, 'null'::jsonb) is distinct from coalesce(v_depois->key, 'null'::jsonb)
      order by key
    loop
      v_campos := array_append(v_campos, v_chave);
    end loop;
  elsif tg_op = 'INSERT' then
    v_campos := array['registro_criado'];
  else
    v_campos := array['registro_excluido'];
  end if;

  insert into public.auditoria_administrativa(ator,perfil,acao,entidade,detalhes)
  values(
    'Aplicação',
    'sistema',
    lower(tg_op),
    tg_table_name,
    jsonb_build_object(
      'id', v_id,
      'campos_alterados', to_jsonb(v_campos),
      'antes', v_antes,
      'depois', v_depois
    )
  );
  return coalesce(new,old);
end $$;

comment on function public.sanitizar_dados_auditoria(jsonb) is
  'Oculta CPFs, senhas, tokens e credenciais antes de registrar antes/depois na auditoria.';

notify pgrst, 'reload schema';
commit;

-- ============================================================================
-- migration_028_mensagens_notificacoes_visualizacoes.sql
-- ============================================================================
begin;

alter table public.convidados add column if not exists visualizado_em timestamptz;
alter table public.reservas_presentes add column if not exists mensagem text;

do $$ begin
  if to_regprocedure('public.buscar_convite_027(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_027;
  end if;
  if to_regprocedure('public.dashboard_noivos_027(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_027;
  end if;
exception when undefined_function then null;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_resultado jsonb;
begin
  update public.convidados
     set visualizado_em=coalesce(visualizado_em,now())
   where codigo_individual=upper(trim(p_codigo));
  select public.buscar_convite_027(p_codigo) into v_resultado;
  return v_resultado;
end $$;

drop function if exists public.registrar_presentes_fisicos(text,jsonb);
create function public.registrar_presentes_fisicos(p_codigo text,p_itens jsonb,p_mensagem text default null)
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
    select coalesce(sum(quantidade),0)::integer into v_usada from public.reservas_presentes where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_usada+v_quantidade>(select quantidade_total from public.presentes where id=v_presente_id) then return false; end if;
    insert into public.reservas_presentes(convite_id,presente_id,quantidade,status,meio,mensagem)
    values(v_convite_id,v_presente_id,v_quantidade,'confirmado','fisico',nullif(left(trim(p_mensagem),1000),''));
  end loop;
  return true;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    (base - 'mensagens') || jsonb_build_object(
      'convidados',coalesce((select jsonb_agg(item || jsonb_build_object('visualizado_em',g.visualizado_em)) from jsonb_array_elements(coalesce(base->'convidados','[]'::jsonb)) item left join public.convidados g on g.id=(item->>'id')::uuid),'[]'::jsonb),
      'mensagens',case when base->>'perfil'='assessoria' then '[]'::jsonb else coalesce((
        select jsonb_agg(m order by m.atualizado_em desc) from (
          select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em
          from public.confirmacoes cf join public.convites c on c.id=cf.convite_id
          where nullif(trim(cf.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,cf.mensagem
          union all
          select c.nome_familia,c.codigo,r.mensagem,max(r.criado_em)
          from public.reservas_presentes r join public.convites c on c.id=r.convite_id
          where nullif(trim(r.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,r.mensagem
        ) m
      ),'[]'::jsonb) end,
      'notificacoes',case when base->>'perfil'='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('grupo',c.nome_familia,'codigo',c.codigo,'mensagem',n.mensagem,'criado_em',n.criado_em) order by n.criado_em desc) from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id),'[]'::jsonb) end
    ) end
  from (select public.dashboard_noivos_027(p_token_hash) base) x;
$$;

revoke all on function public.buscar_convite(text),public.registrar_presentes_fisicos(text,jsonb,text),public.dashboard_noivos(text) from public;
grant execute on function public.buscar_convite(text),public.registrar_presentes_fisicos(text,jsonb,text),public.dashboard_noivos(text) to anon,authenticated;

notify pgrst,'reload schema';
commit;

-- Reservas temporarias de pagamentos rapidos e tratamento de boletos.
begin;

alter table public.reservas_presentes
  add column if not exists tentativa_pagamento_ate timestamptz,
  add column if not exists conciliacao_pagamento_ate timestamptz,
  add column if not exists checkout_url text,
  add column if not exists tipo_pagamento text,
  add column if not exists boleto_vencimento timestamptz;

create index if not exists reservas_pagamento_expiracao_idx
  on public.reservas_presentes (conciliacao_pagamento_ate)
  where meio='mercado_pago' and status='pendente';

create or replace function public.reservar_presentes_pagamento(
  p_codigo text,
  p_itens jsonb,
  p_preferencia_id text,
  p_external_reference text,
  p_checkout_url text,
  p_tentativa_pagamento_ate timestamptz,
  p_conciliacao_pagamento_ate timestamptz,
  p_doador_chave text,
  p_cpf_cifrado text,
  p_cpf_consentimento_em timestamptz,
  p_cpf_politica_versao text,
  p_mensagem text
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_convite_id uuid;
  v_item jsonb;
  v_presente_id uuid;
  v_quantidade integer;
  v_usada integer;
  v_total integer;
begin
  perform public.expirar_reservas_pagamento();

  select c.id into v_convite_id
    from public.convites c
   where c.ativo=true and (
     c.codigo=upper(trim(p_codigo)) or exists (
       select 1 from public.convidados g
        where g.convite_id=c.id
          and g.codigo_individual=upper(trim(p_codigo))
     )
   )
   limit 1;

  if v_convite_id is null
     or jsonb_typeof(p_itens)<>'array'
     or jsonb_array_length(p_itens)<1
     or jsonb_array_length(p_itens)>30
     or nullif(trim(p_preferencia_id),'') is null
     or nullif(trim(p_external_reference),'') is null
     or nullif(trim(p_checkout_url),'') is null
     or p_tentativa_pagamento_ate<=now()
     or p_conciliacao_pagamento_ate<=p_tentativa_pagamento_ate
  then return false; end if;

  for v_item in
    select value from jsonb_array_elements(p_itens)
     order by value->>'presente_id'
  loop
    v_presente_id := (v_item->>'presente_id')::uuid;
    v_quantidade := (v_item->>'quantidade')::integer;
    select quantidade_total into v_total
      from public.presentes
     where id=v_presente_id and ativo=true
     for update;
    if not found or v_quantidade<1 or v_quantidade>20 then
      raise exception 'reserva_indisponivel';
    end if;
    select coalesce(sum(quantidade),0)::integer into v_usada
      from public.reservas_presentes
     where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_usada+v_quantidade>v_total then
      raise exception 'reserva_indisponivel';
    end if;
    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,preferencia_id,
      external_reference,pagamento_status,tentativa_pagamento_ate,
      conciliacao_pagamento_ate,checkout_url,doador_chave,cpf_cifrado,
      cpf_consentimento_em,cpf_politica_versao,mensagem
    ) values (
      v_convite_id,v_presente_id,v_quantidade,'pendente','mercado_pago',
      p_preferencia_id,p_external_reference,'pending',p_tentativa_pagamento_ate,
      p_conciliacao_pagamento_ate,p_checkout_url,p_doador_chave,p_cpf_cifrado,
      p_cpf_consentimento_em,p_cpf_politica_versao,
      nullif(left(trim(p_mensagem),1000),'')
    );
  end loop;
  return true;
exception
  when raise_exception or unique_violation or invalid_text_representation
    or not_null_violation or check_violation then return false;
end $$;

create or replace function public.expirar_reservas_pagamento()
returns integer language plpgsql security definer set search_path=public as $$
declare v_total integer;
begin
  update public.reservas_presentes
     set status='cancelado', pagamento_status='cancelled_by_timeout', atualizado_em=now()
   where meio='mercado_pago' and status='pendente'
     and coalesce(tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
     and conciliacao_pagamento_ate is not null and conciliacao_pagamento_ate<=now();
  get diagnostics v_total = row_count;
  return v_total;
end $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'nome',p.nome,'descricao',p.descricao,'imagens',coalesce(p.imagens,'{}'),
    'categoria_id',p.categoria_id,'categoria',c.nome,'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',greatest(p.quantidade_total-coalesce(r.assinada,0),0)
  ) order by c.ordem nulls last,p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join public.categorias_presentes c on c.id=p.categoria_id and c.ativo
  left join (
    select presente_id,sum(quantidade)::integer assinada
      from public.reservas_presentes
     where status in ('pendente','confirmado')
     group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo;
$$;

create or replace function public.listar_historico_presentes(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_resultado jsonb;
begin
  perform public.expirar_reservas_pagamento();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'presente_id',r.presente_id,'presente',p.nome,'quantidade',r.quantidade,
    'meio',r.meio,'status',r.status,'pagamento_status',r.pagamento_status,
    'editavel',(r.meio='fisico' and r.status='confirmado'),
    'pode_tentar_pagamento',(r.meio='mercado_pago' and r.status='pendente' and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec') and r.tentativa_pagamento_ate>now()),
    'checkout_url',(case when r.meio='mercado_pago' and r.status='pendente' and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec') and r.tentativa_pagamento_ate>now() then r.checkout_url else null end),
    'tentativa_pagamento_ate',r.tentativa_pagamento_ate,'conciliacao_pagamento_ate',r.conciliacao_pagamento_ate,
    'tipo_pagamento',r.tipo_pagamento,'boleto_vencimento',r.boleto_vencimento,
    'criado_em',r.criado_em,'aprovado_em',r.aprovado_em
  ) order by r.criado_em desc),'[]'::jsonb) into v_resultado
  from public.reservas_presentes r
  join public.presentes p on p.id=r.presente_id
  join public.convites c on c.id=r.convite_id
  where c.ativo=true and (c.codigo=upper(trim(p_codigo)) or exists(
    select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo))
  ));
  return v_resultado;
end $$;

revoke all on function public.expirar_reservas_pagamento() from public;
grant execute on function public.expirar_reservas_pagamento() to service_role;
revoke all on function public.reservar_presentes_pagamento(text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text) from public;
grant execute on function public.reservar_presentes_pagamento(text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text) to service_role;
grant execute on function public.listar_presentes() to anon,authenticated;
revoke all on function public.listar_historico_presentes(text) from public;
grant execute on function public.listar_historico_presentes(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;

-- Agenda no próprio Supabase a expiração das reservas a cada cinco minutos.
-- Não depende do Cron da Vercel nem de CRON_SECRET.
begin;

create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'expirar-reservas-pagamento',
  '*/5 * * * *',
  $cron$select public.expirar_reservas_pagamento();$cron$
);

commit;

-- ============================================================================
-- migration_033_revisao_geral_perfis_notificacoes.sql
-- ============================================================================
-- Revisão geral de permissões, sessões, confirmações e notificações.
-- Execute depois da migration_032_supabase_cron_reservas.sql.

begin;

create or replace function public.funcao_reservada_organizacao(p_funcao text)
returns boolean language sql immutable set search_path=public as $$
  select lower(trim(coalesce(p_funcao,''))) in (
    'admin','administrador','administradora','assessor','assessora','assessoria',
    'noivo','noiva','noivos'
  );
$$;

create or replace function public.tem_acesso_lista(p_token_hash text)
returns boolean language sql security definer set search_path=public stable as $$
  select exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  );
$$;

create or replace function public.encerrar_sessao_organizacao_backend(p_token_hash text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  delete from public.sessoes_organizacao where token_hash=p_token_hash;
  return true;
end $$;

create or replace function public.administrar_organizacao_backend(
  p_token_hash text, p_acao text, p_dados jsonb, p_hash text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_admin public.organizacao%rowtype;
  v_alvo public.organizacao%rowtype;
  v_codigo text;
  v_usuario text;
begin
  select o.* into v_admin
  from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and o.administrador;
  if not found then return jsonb_build_object('ok',false); end if;

  if p_acao='criar' then
    v_usuario:=lower(trim(p_dados->>'usuario'));
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then return jsonb_build_object('ok',false); end if;
    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.organizacao where codigo=v_codigo)
        and not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
    end loop;
    insert into public.organizacao(
      usuario,codigo,nome,funcao,administrador,senha_hash,exige_troca_senha
    ) values(
      v_usuario,v_codigo,trim(p_dados->>'nome'),p_dados->>'funcao',
      coalesce((p_dados->>'administrador')::boolean,false),p_hash,true
    );
    return jsonb_build_object('ok',true,'codigo',v_codigo);
  end if;

  select * into v_alvo from public.organizacao where id=(p_dados->>'id')::uuid;
  if not found then return jsonb_build_object('ok',false); end if;

  if p_acao='editar' then
    if v_alvo.principal then return jsonb_build_object('ok',false); end if;
    update public.organizacao set
      nome=trim(p_dados->>'nome'),
      usuario=lower(trim(p_dados->>'usuario')),
      funcao=p_dados->>'funcao',
      administrador=coalesce((p_dados->>'administrador')::boolean,false),
      atualizado_em=now()
    where id=v_alvo.id;
  elsif p_acao in ('resetar_senha','definir_senha') then
    if v_alvo.principal or p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then return jsonb_build_object('ok',false); end if;
    update public.organizacao set
      senha_hash=p_hash,exige_troca_senha=true,atualizado_em=now()
    where id=v_alvo.id;
    delete from public.sessoes_organizacao where organizacao_id=v_alvo.id;
  else
    return jsonb_build_object('ok',false);
  end if;
  return jsonb_build_object('ok',true);
exception when unique_violation or invalid_text_representation or check_violation or not_null_violation then
  return jsonb_build_object('ok',false);
end $$;

create or replace function public.administrar_grupos(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_alvo public.convites%rowtype; v_codigo text; v_titulo text;
begin
  if not public.tem_acesso_lista(p_token_hash) then return false; end if;
  v_codigo:=upper(trim(coalesce(p_dados->>'codigo','')));
  v_titulo:=trim(coalesce(p_dados->>'titulo',''));
  if v_codigo !~ '^[A-Z0-9]{6}$' or length(v_titulo) not between 2 and 100
    or exists(select 1 from public.organizacao where codigo=v_codigo)
    or exists(select 1 from public.convidados where codigo_individual=v_codigo)
  then return false; end if;

  if p_acao='criar' then
    if exists(select 1 from public.convites where codigo=v_codigo) then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_titulo,1,'convidado',true);
  elsif p_acao='editar' then
    select * into v_alvo from public.convites where id=(p_dados->>'id')::uuid;
    if not found or exists(select 1 from public.convites where codigo=v_codigo and id<>v_alvo.id)
    then return false; end if;
    update public.convites set codigo=v_codigo,nome_familia=v_titulo,atualizado_em=now()
    where id=v_alvo.id;
  else return false; end if;
  return true;
exception when invalid_text_representation or unique_violation or check_violation then return false;
end $$;

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_perfil text;
  v_convite_id uuid;
  v_convite_anterior uuid;
  v_codigo text;
  v_nome text;
  v_funcao text;
  v_origem text;
  v_status text;
  v_grupo_individual boolean:=false;
begin
  select case when o.administrador then 'admin'
    when o.funcao in ('noivo','noiva') then 'noivos' else 'assessoria' end
  into v_perfil
  from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;
  if v_perfil is null then return false; end if;
  if v_perfil='assessoria' and p_acao not in ('editar_restrito','presenca') then return false; end if;

  v_nome:=trim(coalesce(p_dados->>'nome',''));
  v_funcao:=nullif(trim(coalesce(p_dados->>'funcao','')),'');
  v_origem:=coalesce(p_dados->>'origem','nao_classificado');
  if public.funcao_reservada_organizacao(v_funcao) then return false; end if;

  if p_acao in ('editar','editar_restrito','remover','presenca') then
    select g.convite_id,(c.codigo=g.codigo_individual)
      into v_convite_id,v_grupo_individual
    from public.convidados g join public.convites c on c.id=g.convite_id
    where g.id=(p_dados->>'id')::uuid;
    if v_convite_id is null then return false; end if;
  end if;

  if p_acao='adicionar' then
    if length(v_nome) not between 2 and 150
      or v_origem not in ('noivo','noiva','ambos','nao_classificado') then return false; end if;
    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo)
        and not exists(select 1 from public.organizacao where codigo=v_codigo);
    end loop;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_nome,1,'convidado',true) returning id into v_convite_id;
    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem,crianca
    ) values(
      v_convite_id,v_nome,false,true,1,v_funcao,v_codigo,v_origem,
      coalesce((p_dados->>'crianca')::boolean,false)
    );
  elsif p_acao='editar' then
    if length(v_nome) not between 2 and 150
      or v_origem not in ('noivo','noiva','ambos','nao_classificado') then return false; end if;
    v_convite_anterior:=v_convite_id;
    select id into v_convite_id from public.convites where codigo=upper(trim(p_dados->>'codigo')) and ativo;
    if v_convite_id is null then return false; end if;
    update public.confirmacoes set convite_id=v_convite_id where convidado_id=(p_dados->>'id')::uuid;
    update public.convidados set
      convite_id=v_convite_id,nome=v_nome,principal=false,
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      funcao=v_funcao,origem=v_origem,
      crianca=coalesce((p_dados->>'crianca')::boolean,crianca)
    where id=(p_dados->>'id')::uuid;
    if not found then return false; end if;
    if v_grupo_individual and v_convite_anterior=v_convite_id then
      update public.convites set nome_familia=v_nome,atualizado_em=now() where id=v_convite_id;
    elsif v_grupo_individual then
      delete from public.convites c where c.id=v_convite_anterior
        and not exists(select 1 from public.convidados g where g.convite_id=c.id)
        and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    end if;
  elsif p_acao='editar_restrito' then
    update public.convidados set funcao=v_funcao where id=(p_dados->>'id')::uuid;
    if not found then return false; end if;
  elsif p_acao='presenca' then
    v_status=p_dados->>'status';
    if v_status='aguardando' then
      delete from public.confirmacoes where convidado_id=(p_dados->>'id')::uuid;
    elsif v_status in ('sim','nao') then
      insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
      values(v_convite_id,(p_dados->>'id')::uuid,v_status,now())
      on conflict(convite_id,convidado_id) do update set status=excluded.status,atualizado_em=now();
    else return false; end if;
  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
    if not found then return false; end if;
    if v_grupo_individual then
      delete from public.convites c where c.id=v_convite_id
        and not exists(select 1 from public.convidados g where g.convite_id=c.id)
        and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    end if;
  else return false; end if;
  return true;
exception when unique_violation or invalid_text_representation or not_null_violation or check_violation then
  return false;
end $$;

create or replace function public.administrar_convidado_com_codigo(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_codigo text:=upper(trim(coalesce(p_dados->>'codigo_individual','')));
  v_nome text:=trim(coalesce(p_dados->>'nome',''));
  v_funcao text:=nullif(trim(coalesce(p_dados->>'funcao','')),'');
  v_origem text:=coalesce(p_dados->>'origem','nao_classificado');
  v_id uuid; v_convite_id uuid; v_convite_atual uuid; v_convite_destino uuid;
  v_codigo_antigo text; v_grupo_individual boolean:=false;
begin
  if p_acao not in ('adicionar_com_codigo','editar_com_codigo')
    or v_codigo !~ '^[A-Z0-9]{6}$' or length(v_nome) not between 2 and 150
    or v_origem not in ('noivo','noiva','ambos','nao_classificado')
    or public.funcao_reservada_organizacao(v_funcao)
    or not public.tem_acesso_lista(p_token_hash) then return false; end if;
  perform pg_advisory_xact_lock(hashtext(v_codigo));

  if p_acao='adicionar_com_codigo' then
    if exists(select 1 from public.convites where codigo=v_codigo)
      or exists(select 1 from public.convidados where codigo_individual=v_codigo)
      or exists(select 1 from public.organizacao where codigo=v_codigo) then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_nome,1,'convidado',true) returning id into v_convite_id;
    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem,crianca
    ) values(
      v_convite_id,v_nome,false,true,1,v_funcao,v_codigo,v_origem,
      coalesce((p_dados->>'crianca')::boolean,false)
    );
    return true;
  end if;

  v_id:=nullif(p_dados->>'id','')::uuid;
  select g.convite_id,g.codigo_individual,(c.codigo=g.codigo_individual)
    into v_convite_atual,v_codigo_antigo,v_grupo_individual
  from public.convidados g join public.convites c on c.id=g.convite_id where g.id=v_id;
  if v_id is null or v_convite_atual is null
    or exists(select 1 from public.convites where codigo=v_codigo and id<>v_convite_atual)
    or exists(select 1 from public.organizacao where codigo=v_codigo)
    or exists(select 1 from public.convidados where codigo_individual=v_codigo and id<>v_id)
  then return false; end if;
  select id into v_convite_destino from public.convites where codigo=upper(trim(p_dados->>'codigo')) and ativo;
  if v_convite_destino is null then return false; end if;
  update public.confirmacoes set convite_id=v_convite_destino where convidado_id=v_id;
  update public.convidados set
    convite_id=v_convite_destino,nome=v_nome,principal=false,
    pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
    funcao=v_funcao,codigo_individual=v_codigo,origem=v_origem,
    crianca=coalesce((p_dados->>'crianca')::boolean,crianca)
  where id=v_id;
  if not found then return false; end if;
  if v_grupo_individual and v_convite_atual=v_convite_destino then
    update public.convites set codigo=v_codigo,nome_familia=v_nome,atualizado_em=now()
    where id=v_convite_atual and codigo=v_codigo_antigo;
  elsif v_grupo_individual then
    delete from public.convites c where c.id=v_convite_atual
      and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
  end if;
  return true;
exception when unique_violation or invalid_text_representation or not_null_violation or check_violation then
  return false;
end $$;

create or replace function public.importar_convidados_automatico(
  p_token_hash text,p_linhas jsonb
) returns integer language plpgsql security definer set search_path=public as $$
declare
  v_item jsonb; v_codigo text; v_codigo_individual text; v_nome text;
  v_grupo text; v_funcao text; v_origem text; v_convite_id uuid;
  v_ordem integer; v_total integer:=0;
begin
  if not public.tem_acesso_lista(p_token_hash) then return -1; end if;
  if jsonb_typeof(p_linhas)<>'array' or jsonb_array_length(p_linhas) not between 1 and 1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(coalesce(v_item->>'nome',''));
    v_funcao:=nullif(trim(coalesce(v_item->>'funcao','')),'');
    v_origem:=coalesce(v_item->>'origem','nao_classificado');
    if length(v_nome) not between 2 and 150
      or v_origem not in ('noivo','noiva','ambos','nao_classificado')
      or public.funcao_reservada_organizacao(v_funcao) then return -2; end if;
  end loop;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(v_item->>'nome');
    v_grupo:=nullif(trim(coalesce(v_item->>'grupo','')),'');
    v_funcao:=nullif(trim(coalesce(v_item->>'funcao','')),'');
    v_origem:=coalesce(v_item->>'origem','nao_classificado');
    v_convite_id:=null;
    if v_grupo is not null then
      select id into v_convite_id from public.convites
      where ativo and lower(trim(nome_familia))=lower(v_grupo) order by criado_em limit 1;
    end if;
    if v_convite_id is null then
      loop
        v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
        exit when not exists(select 1 from public.convites where codigo=v_codigo)
          and not exists(select 1 from public.convidados where codigo_individual=v_codigo)
          and not exists(select 1 from public.organizacao where codigo=v_codigo);
      end loop;
      insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
      values(v_codigo,coalesce(v_grupo,v_nome),1,'convidado',true) returning id into v_convite_id;
    end if;
    loop
      v_codigo_individual:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo_individual)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo_individual)
        and not exists(select 1 from public.organizacao where codigo=v_codigo_individual);
    end loop;
    select coalesce(max(ordem),0)+1 into v_ordem from public.convidados where convite_id=v_convite_id;
    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem
    ) values(v_convite_id,v_nome,v_ordem=1,v_ordem=1,v_ordem,v_funcao,v_codigo_individual,v_origem);
    v_total:=v_total+1;
  end loop;
  return v_total;
exception when unique_violation or invalid_text_representation or not_null_violation or check_violation then return -2;
end $$;

create or replace function public.salvar_confirmacao(
  p_codigo text,p_respostas jsonb,p_mensagem text default null
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_convite_id uuid; v_item jsonb; v_id uuid; v_status text; v_anterior text;
  v_idade smallint; v_limite smallint; v_prazo_vencido boolean; v_tinha_confirmado boolean;
begin
  select c.id,(not c.sem_expiracao and c.expira_em<=now()),
    exists(select 1 from public.confirmacoes cf where cf.convite_id=c.id and cf.status='sim')
  into v_convite_id,v_prazo_vencido,v_tinha_confirmado
  from public.convidados gestor join public.convites c on c.id=gestor.convite_id
  where gestor.codigo_individual=upper(trim(p_codigo)) and gestor.pode_gerenciar and c.ativo;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  if v_convite_id is null or jsonb_typeof(p_respostas)<>'array'
    or jsonb_array_length(p_respostas)<1
    or (v_prazo_vencido and not v_tinha_confirmado) then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_id=(v_item->>'convidado_id')::uuid;
    v_status=v_item->>'status';
    if v_status not in ('sim','nao') or not exists(
      select 1 from public.convidados where id=v_id and convite_id=v_convite_id
    ) then return false; end if;
    select status into v_anterior from public.confirmacoes where convidado_id=v_id;
    if v_status='sim' and exists(select 1 from public.convidados where id=v_id and crianca) then
      v_idade=(v_item->>'idade')::smallint;
      if v_idade is null or v_idade not between 0 and 17 then return false; end if;
      update public.convidados set idade_confirmada=v_idade,crianca=(v_idade<=v_limite) where id=v_id;
    end if;
    insert into public.confirmacoes(convite_id,convidado_id,status,mensagem,atualizado_em)
    values(v_convite_id,v_id,v_status,nullif(trim(p_mensagem),''),now())
    on conflict(convite_id,convidado_id) do update set
      status=excluded.status,mensagem=excluded.mensagem,atualizado_em=now();
    perform public.registrar_notificacao_status(v_convite_id,v_id,v_anterior,v_status,'convite');
  end loop;
  if v_prazo_vencido and not exists(
    select 1 from public.confirmacoes where convite_id=v_convite_id and status='sim'
  ) then delete from public.confirmacoes where convite_id=v_convite_id; end if;
  return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end $$;

create or replace function public.adicionar_crianca_grupo(
  p_codigo text,p_nome text,p_idade smallint,p_solicitante text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_convite public.convites%rowtype; v_gestor public.convidados%rowtype;
  v_limite smallint; v_usadas integer; v_codigo text; v_id uuid;
begin
  select g.* into v_gestor from public.convidados g
  where g.codigo_individual=upper(trim(p_codigo)) and g.pode_gerenciar;
  if not found then return jsonb_build_object('ok',false,'motivo','sem_permissao'); end if;
  select * into v_convite from public.convites
  where id=v_gestor.convite_id and ativo and (sem_expiracao or expira_em>now());
  if not found or length(trim(p_nome))<2 or p_idade<0 then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
  end if;
  if p_idade>=18 then
    insert into public.mensagens_organizacao(
      convite_id,pessoa_solicitante,pessoa_solicitada,idade,mensagem
    ) values(
      v_convite.id,v_gestor.nome,trim(p_nome),p_idade,
      'Grupo familiar: '||v_convite.nome_familia||'. '||v_gestor.nome||
      ' solicitou a inclusão de '||trim(p_nome)||', '||p_idade||' anos, como adulto.'
    );
    return jsonb_build_object('ok',false,'motivo','adulto_notificado');
  end if;
  select count(*) into v_usadas from public.convidados
  where convite_id=v_convite.id and adicionado_pelo_responsavel;
  if v_usadas>=v_convite.criancas_adicionais_limite then
    return jsonb_build_object('ok',false,'motivo','limite_atingido');
  end if;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  loop
    v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
    exit when not exists(select 1 from public.convidados where codigo_individual=v_codigo)
      and not exists(select 1 from public.convites where codigo=v_codigo)
      and not exists(select 1 from public.organizacao where codigo=v_codigo);
  end loop;
  insert into public.convidados(
    convite_id,nome,principal,pode_gerenciar,ordem,codigo_individual,
    crianca,idade_confirmada,adicionado_pelo_responsavel
  ) values(
    v_convite.id,trim(p_nome),false,false,
    coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite.id),1),
    v_codigo,p_idade<=v_limite,p_idade,true
  ) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id,'crianca',p_idade<=v_limite,
    'restantes',v_convite.criancas_adicionais_limite-v_usadas-1);
end $$;

create or replace function public.administrar_expiracao(
  p_token_hash text,p_convite_id uuid,p_acao text,p_data timestamptz default null
) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.tem_acesso_lista(p_token_hash) then return false; end if;
  if p_acao='resetar_7_dias' then
    update public.convites set expira_em=public.prazo_padrao_convite(),sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='definir_data' and p_data is not null then
    update public.convites set expira_em=p_data,sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='expirar' then
    update public.convites set expira_em=now()-interval '1 second',sem_expiracao=false,atualizado_em=now() where id=p_convite_id;
  elsif p_acao='retirar_expiracao' then
    update public.convites set expira_em=null,sem_expiracao=true,atualizado_em=now() where id=p_convite_id;
  else return false; end if;
  return found;
end $$;

create or replace function public.administrar_configuracoes_convites(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_admin boolean; v_lista boolean; v_ordem integer;
begin
  v_lista:=public.tem_acesso_lista(p_token_hash);
  select exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo and o.administrador
  ) into v_admin;
  if p_acao='categoria_presente' and v_lista then
    update public.presentes set categoria_id=nullif(p_dados->>'categoria_id','')::uuid
    where id=(p_dados->>'presente_id')::uuid;
    return found;
  end if;
  if not v_admin then return false; end if;
  if p_acao='gerais' then
    update public.configuracoes_convites set
      url_base=rtrim(trim(p_dados->>'url_base'),'/'),
      titulo_site=left(trim(p_dados->>'titulo_site'),120),
      mensagem_confirmacao=left(trim(p_dados->>'mensagem_confirmacao'),500),
      dias_expiracao_padrao=greatest(1,least(365,(p_dados->>'dias_expiracao_padrao')::integer)),
      atualizado_em=now() where id;
    return found;
  elsif p_acao='criar_categoria' then
    select coalesce(max(ordem),0)+1 into v_ordem from public.categorias_presentes;
    insert into public.categorias_presentes(nome,ordem) values(left(trim(p_dados->>'nome'),80),v_ordem);
  elsif p_acao='editar_categoria' then
    update public.categorias_presentes set nome=left(trim(p_dados->>'nome'),80) where id=(p_dados->>'id')::uuid;
  elsif p_acao='desativar_categoria' then
    update public.presentes set categoria_id=null where categoria_id=(p_dados->>'id')::uuid;
    update public.categorias_presentes set ativo=false where id=(p_dados->>'id')::uuid;
  elsif p_acao='mover_categoria' then
    update public.categorias_presentes set ordem=ordem+((p_dados->>'direcao')::integer) where id=(p_dados->>'id')::uuid;
  else return false; end if;
  return true;
exception when unique_violation or invalid_text_representation or not_null_violation then return false;
end $$;

do $$ begin
  if to_regprocedure('public.buscar_convite_032(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_032;
  end if;
  if to_regprocedure('public.dashboard_noivos_032(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_032;
  end if;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_resultado jsonb; v_convidados jsonb;
begin
  select public.buscar_convite_032(p_codigo) into v_resultado;
  if v_resultado is null then return null; end if;
  if v_resultado->>'perfil_acesso'='convidado'
    and not coalesce((v_resultado->>'pode_gerenciar')::boolean,false) then
    select coalesce(jsonb_agg(
      case when item->>'codigo_individual'=upper(trim(p_codigo)) then item
      else item || jsonb_build_object('codigo_individual','PROTEGIDO') end
      order by ordem
    ),'[]'::jsonb) into v_convidados
    from jsonb_array_elements(coalesce(v_resultado->'convidados','[]'::jsonb)) with ordinality as x(item,ordem);
    v_resultado:=v_resultado || jsonb_build_object('convidados',v_convidados);
  end if;
  return v_resultado;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    (base-'organizacao'-'notificacoes') || jsonb_build_object(
      'organizacao',case when base->>'perfil'='admin'
        then coalesce(base->'organizacao','[]'::jsonb) else '[]'::jsonb end,
      'notificacoes',case when base->>'perfil'='assessoria' then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object(
          'grupo',n.grupo,'codigo',n.codigo,'mensagem',n.mensagem,'criado_em',n.criado_em
        ) order by n.criado_em desc)
        from (
          select c.nome_familia grupo,c.codigo,n.mensagem,n.criado_em
          from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id
          union all
          select c.nome_familia,c.codigo,m.mensagem,m.criado_em
          from public.mensagens_organizacao m join public.convites c on c.id=m.convite_id
        ) n
      ),'[]'::jsonb) end
    ) end
  from (select public.dashboard_noivos_032(p_token_hash) base) x;
$$;

revoke all on function public.funcao_reservada_organizacao(text) from public;
revoke all on function public.tem_acesso_lista(text) from public;
revoke all on function public.encerrar_sessao_organizacao_backend(text) from public;
revoke all on function public.administrar_organizacao_backend(text,text,jsonb,text) from public;
grant execute on function public.encerrar_sessao_organizacao_backend(text) to service_role;
grant execute on function public.administrar_organizacao_backend(text,text,jsonb,text) to service_role;

revoke all on function public.buscar_convite_018(text) from public;
revoke all on function public.buscar_convite_027(text) from public;
revoke all on function public.buscar_convite_032(text) from public;
revoke all on function public.dashboard_noivos_018(text) from public;
revoke all on function public.dashboard_noivos_027(text) from public;
revoke all on function public.dashboard_noivos_032(text) from public;
revoke all on function public.administrar_convidados_020(text,text,jsonb) from public;
revoke all on function public.buscar_convite_018(text) from anon,authenticated;
revoke all on function public.buscar_convite_027(text) from anon,authenticated;
revoke all on function public.buscar_convite_032(text) from anon,authenticated;
revoke all on function public.dashboard_noivos_018(text) from anon,authenticated;
revoke all on function public.dashboard_noivos_027(text) from anon,authenticated;
revoke all on function public.dashboard_noivos_032(text) from anon,authenticated;
revoke all on function public.administrar_convidados_020(text,text,jsonb) from anon,authenticated;

revoke all on function public.buscar_convite(text) from public;
revoke all on function public.dashboard_noivos(text) from public;
revoke all on function public.administrar_grupos(text,text,jsonb) from public;
revoke all on function public.administrar_convidados(text,text,jsonb) from public;
revoke all on function public.administrar_convidado_com_codigo(text,text,jsonb) from public;
revoke all on function public.importar_convidados_automatico(text,jsonb) from public;
revoke all on function public.salvar_confirmacao(text,jsonb,text) from public;
revoke all on function public.adicionar_crianca_grupo(text,text,smallint,text) from public;
revoke all on function public.administrar_expiracao(text,uuid,text,timestamptz) from public;
revoke all on function public.administrar_configuracoes_convites(text,text,jsonb) from public;

grant execute on function public.buscar_convite(text),public.dashboard_noivos(text),
  public.administrar_grupos(text,text,jsonb),public.administrar_convidados(text,text,jsonb),
  public.administrar_convidado_com_codigo(text,text,jsonb),
  public.importar_convidados_automatico(text,jsonb),public.salvar_confirmacao(text,jsonb,text),
  public.adicionar_crianca_grupo(text,text,smallint,text),
  public.administrar_expiracao(text,uuid,text,timestamptz),
  public.administrar_configuracoes_convites(text,text,jsonb)
to anon,authenticated;

notify pgrst,'reload schema';
commit;

-- ============================================================================
-- migration_034_codigos_organizacao_login.sql
-- ============================================================================
-- Códigos personalizados da organização e login unificado por usuário ou código.

begin;

create or replace function public.administrar_organizacao_backend(
  p_token_hash text, p_acao text, p_dados jsonb, p_hash text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_admin public.organizacao%rowtype;
  v_alvo public.organizacao%rowtype;
  v_codigo text;
  v_usuario text;
  v_nome text;
  v_funcao text;
  v_administrador boolean;
begin
  select o.* into v_admin
  from public.sessoes_organizacao s
  join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and o.ativo and o.administrador;
  if not found then
    return jsonb_build_object('ok',false,'motivo','acesso_negado');
  end if;

  v_usuario:=lower(trim(coalesce(p_dados->>'usuario','')));
  v_nome:=trim(coalesce(p_dados->>'nome',''));
  v_funcao:=trim(coalesce(p_dados->>'funcao',''));
  v_administrador:=coalesce((p_dados->>'administrador')::boolean,false)
    or v_funcao='administrador';
  v_codigo:=upper(trim(coalesce(p_dados->>'codigo','')));

  if p_acao='criar' then
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or v_funcao not in ('administrador','noivo','noiva','assessoria')
      or p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then
      return jsonb_build_object('ok',false,'motivo','dados_invalidos');
    end if;
    if exists(select 1 from public.organizacao where lower(usuario)=v_usuario) then
      return jsonb_build_object('ok',false,'motivo','usuario_indisponivel');
    end if;

    if v_codigo='' then
      loop
        v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
        perform pg_advisory_xact_lock(hashtext(v_codigo));
        exit when not exists(select 1 from public.organizacao where codigo=v_codigo)
          and not exists(select 1 from public.convites where codigo=v_codigo)
          and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
      end loop;
    else
      if v_codigo !~ '^[A-Z0-9]{6}$' then
        return jsonb_build_object('ok',false,'motivo','codigo_invalido');
      end if;
      perform pg_advisory_xact_lock(hashtext(v_codigo));
      if exists(select 1 from public.organizacao where codigo=v_codigo)
        or exists(select 1 from public.convites where codigo=v_codigo)
        or exists(select 1 from public.convidados where codigo_individual=v_codigo)
      then
        return jsonb_build_object('ok',false,'motivo','codigo_indisponivel');
      end if;
    end if;

    insert into public.organizacao(
      usuario,codigo,nome,funcao,administrador,senha_hash,exige_troca_senha
    ) values(
      v_usuario,v_codigo,v_nome,v_funcao,v_administrador,p_hash,true
    );
    return jsonb_build_object('ok',true,'codigo',v_codigo);
  end if;

  select * into v_alvo
  from public.organizacao
  where id=nullif(p_dados->>'id','')::uuid;
  if not found or v_alvo.principal then
    return jsonb_build_object('ok',false,'motivo','acesso_negado');
  end if;

  if p_acao='editar' then
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or v_funcao not in ('administrador','noivo','noiva','assessoria')
    then
      return jsonb_build_object('ok',false,'motivo','dados_invalidos');
    end if;
    if v_codigo !~ '^[A-Z0-9]{6}$' then
      return jsonb_build_object('ok',false,'motivo','codigo_invalido');
    end if;
    perform pg_advisory_xact_lock(hashtext(v_codigo));
    if exists(
      select 1 from public.organizacao
      where lower(usuario)=v_usuario and id<>v_alvo.id
    ) then
      return jsonb_build_object('ok',false,'motivo','usuario_indisponivel');
    end if;
    if exists(select 1 from public.organizacao where codigo=v_codigo and id<>v_alvo.id)
      or exists(select 1 from public.convites where codigo=v_codigo)
      or exists(select 1 from public.convidados where codigo_individual=v_codigo)
    then
      return jsonb_build_object('ok',false,'motivo','codigo_indisponivel');
    end if;

    update public.organizacao set
      nome=v_nome,
      usuario=v_usuario,
      codigo=v_codigo,
      funcao=v_funcao,
      administrador=v_administrador,
      atualizado_em=now()
    where id=v_alvo.id;
    return jsonb_build_object('ok',true,'codigo',v_codigo);
  elsif p_acao in ('resetar_senha','definir_senha') then
    if p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then
      return jsonb_build_object('ok',false,'motivo','dados_invalidos');
    end if;
    update public.organizacao set
      senha_hash=p_hash,exige_troca_senha=true,atualizado_em=now()
    where id=v_alvo.id;
    delete from public.sessoes_organizacao where organizacao_id=v_alvo.id;
    return jsonb_build_object('ok',true,'codigo',v_alvo.codigo);
  end if;

  return jsonb_build_object('ok',false,'motivo','dados_invalidos');
exception
  when unique_violation then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
  when invalid_text_representation or check_violation or not_null_violation then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
end $$;

revoke all on function public.administrar_organizacao_backend(text,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.administrar_organizacao_backend(text,text,jsonb,text)
  to service_role;

notify pgrst,'reload schema';
commit;

-- Garantias finais de instalacao limpa.
-- As tabelas de negocio permanecem vazias. A conta admin estrutural e as linhas
-- singleton de configuracao sao necessarias para inicializar o aplicativo.
delete from public.confirmacoes;
delete from public.reservas_presentes;
delete from public.presentes;
delete from public.convidados;
delete from public.convites;
delete from public.notificacoes_organizacao;
delete from public.falhas_webhook_pagamento;
delete from public.auditoria_administrativa;
delete from public.sessoes_noivos;
delete from public.sessoes_organizacao;
delete from public.organizacao where usuario <> 'admin';
update public.organizacao
set nome='Administrador principal', funcao='administrador', administrador=true,
    principal=true, codigo=null, senha_hash=null, exige_troca_senha=false,
    ativo=true, atualizado_em=now()
where usuario='admin';

-- Remove eventos tecnicos gerados pelos gatilhos durante a propria instalacao.
delete from public.auditoria_administrativa;

commit;

-- ============================================================================
-- migration_035_grupos_integrados_convidados.sql
-- ============================================================================
begin;

-- Permite criar um convidado diretamente em um grupo existente. Quando o
-- código individual não é informado, ele continua sendo gerado no banco.
create or replace function public.administrar_convidado_com_codigo(
  p_token_hash text, p_acao text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo_individual','')));
  v_codigo_grupo text := upper(trim(coalesce(p_dados->>'codigo','')));
  v_nome text := trim(coalesce(p_dados->>'nome',''));
  v_funcao text := nullif(trim(coalesce(p_dados->>'funcao','')),'');
  v_origem text := coalesce(p_dados->>'origem','nao_classificado');
  v_id uuid;
  v_convite_id uuid;
  v_convite_atual uuid;
  v_convite_destino uuid;
  v_codigo_antigo text;
  v_grupo_individual boolean := false;
begin
  if p_acao not in ('adicionar_com_codigo','editar_com_codigo')
    or length(v_nome) not between 2 and 150
    or v_origem not in ('noivo','noiva','ambos','nao_classificado')
    or not exists (
      select 1
      from public.sessoes_organizacao s
      join public.organizacao o on o.id=s.organizacao_id
      where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
        and (o.administrador or o.funcao in ('noivo','noiva'))
    ) then return false; end if;

  if p_acao='adicionar_com_codigo' and v_codigo='' then
    loop
      v_codigo:=upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo)
        and not exists(select 1 from public.organizacao where codigo=v_codigo);
    end loop;
  end if;

  if v_codigo !~ '^[A-Z0-9]{6}$' then return false; end if;
  perform pg_advisory_xact_lock(hashtext(v_codigo));

  if p_acao='adicionar_com_codigo' then
    if exists(select 1 from public.convites where codigo=v_codigo)
      or exists(select 1 from public.convidados where codigo_individual=v_codigo)
      or exists(select 1 from public.organizacao where codigo=v_codigo)
      then return false; end if;

    if v_codigo_grupo<>'' then
      select id into v_convite_id
      from public.convites
      where codigo=v_codigo_grupo and ativo;
      if v_convite_id is null then return false; end if;
    else
      insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
      values(v_codigo,v_nome,1,'convidado',true)
      returning id into v_convite_id;
    end if;

    insert into public.convidados(
      convite_id,nome,principal,pode_gerenciar,ordem,funcao,
      codigo_individual,origem,crianca
    ) values(
      v_convite_id,v_nome,coalesce((p_dados->>'principal')::boolean,false),
      coalesce((p_dados->>'pode_gerenciar')::boolean,true),
      coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
      v_funcao,v_codigo,v_origem,coalesce((p_dados->>'crianca')::boolean,false)
    );
    return true;
  end if;

  v_id:=nullif(p_dados->>'id','')::uuid;
  select g.convite_id,g.codigo_individual,(c.codigo=g.codigo_individual)
    into v_convite_atual,v_codigo_antigo,v_grupo_individual
    from public.convidados g
    join public.convites c on c.id=g.convite_id
    where g.id=v_id;
  if v_id is null or v_convite_atual is null
    or exists(select 1 from public.convites where codigo=v_codigo and id<>v_convite_atual)
    or exists(select 1 from public.organizacao where codigo=v_codigo)
    or exists(select 1 from public.convidados where codigo_individual=v_codigo and id<>v_id)
    then return false; end if;

  select id into v_convite_destino
  from public.convites
  where codigo=v_codigo_grupo and ativo;
  if v_convite_destino is null then return false; end if;

  update public.confirmacoes set convite_id=v_convite_destino where convidado_id=v_id;
  update public.convidados set
    convite_id=v_convite_destino,
    nome=v_nome,
    principal=coalesce((p_dados->>'principal')::boolean,false),
    pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
    funcao=v_funcao,
    codigo_individual=v_codigo,
    origem=v_origem,
    crianca=coalesce((p_dados->>'crianca')::boolean,crianca)
  where id=v_id;

  if v_grupo_individual and v_convite_atual=v_convite_destino then
    update public.convites set codigo=v_codigo
    where id=v_convite_atual and codigo=v_codigo_antigo;
  elsif v_grupo_individual then
    delete from public.convites c
    where c.id=v_convite_atual
      and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
  end if;
  return found;
exception
  when unique_violation or invalid_text_representation or not_null_violation then
    return false;
end $$;

revoke all on function public.administrar_convidado_com_codigo(text,text,jsonb) from public;
grant execute on function public.administrar_convidado_com_codigo(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';

commit;
+-- ============================================================================
-- migration_036_modelos_duplicidades_gestao_presentes.sql
-- ============================================================================
begin;

-- Evita duplicidades acidentais na importação. Uma repetição só é inserida
-- quando foi revisada e marcada explicitamente como outro item pela interface.
create or replace function public.importar_presentes_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb; v_nome text; v_categoria text; v_categoria_id uuid;
  v_descricao text; v_imagens text[]; v_valor numeric; v_quantidade integer;
  v_ordem integer; v_total integer := 0; v_permitir_duplicado boolean;
  v_nome_normalizado text;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array'
    or jsonb_array_length(p_linhas) not between 1 and 1000
  then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_categoria := trim(coalesce(v_item->>'categoria',''));
    v_descricao := nullif(trim(coalesce(v_item->>'descricao','')), '');
    v_valor := (v_item->>'valor')::numeric;
    v_quantidade := greatest(
      1,
      least(10000, coalesce((v_item->>'quantidade')::integer,1))
    );
    v_permitir_duplicado := coalesce(
      (v_item->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value), '{}') into v_imagens
    from jsonb_array_elements_text(
      coalesce(v_item->'links_fotos','[]'::jsonb)
    );
    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2
      or v_valor<0 or v_valor>1000000 or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
    then return -2; end if;

    v_nome_normalizado := lower(
      regexp_replace(trim(v_nome), '[[:space:]]+', ' ', 'g')
    );
    if not v_permitir_duplicado and exists (
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome), '[[:space:]]+', ' ', 'g'))
          = v_nome_normalizado
    ) then
      continue;
    end if;

    select id into v_categoria_id
    from public.categorias_presentes
    where lower(trim(nome))=lower(v_categoria)
    order by ativo desc, ordem
    limit 1;
    if v_categoria_id is null then
      select coalesce(max(ordem),0)+1 into v_ordem
      from public.categorias_presentes;
      insert into public.categorias_presentes(nome,ordem)
      values(v_categoria,v_ordem)
      returning id into v_categoria_id;
    else
      update public.categorias_presentes set ativo=true where id=v_categoria_id;
    end if;

    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(
      nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
    ) values(
      v_nome,v_descricao,round(v_valor*100)::integer,v_quantidade,
      v_ordem,v_categoria_id,v_imagens
    );
    v_total := v_total + 1;
  end loop;
  return v_total;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return -2;
end $$;

-- Cadastro manual e remoção segura. A exclusão é lógica para que assinaturas,
-- pagamentos e auditoria continuem íntegros mesmo após o item sair da lista.
create or replace function public.administrar_presente_dashboard(
  p_token_hash text,
  p_acao text,
  p_dados jsonb
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid; v_nome text; v_descricao text; v_categoria_id uuid;
  v_preco_centavos integer; v_quantidade_total integer; v_imagens text[];
  v_ordem integer; v_permitir_duplicado boolean; v_nome_normalizado text;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;

  if p_acao='criar' then
    v_nome:=trim(coalesce(p_dados->>'nome',''));
    v_descricao:=nullif(trim(coalesce(p_dados->>'descricao','')),'');
    v_categoria_id:=nullif(p_dados->>'categoria_id','')::uuid;
    v_preco_centavos:=(p_dados->>'preco_centavos')::integer;
    v_quantidade_total:=(p_dados->>'quantidade_total')::integer;
    v_permitir_duplicado:=coalesce(
      (p_dados->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value), '{}') into v_imagens
    from jsonb_array_elements_text(coalesce(p_dados->'imagens','[]'::jsonb));

    if length(v_nome) not between 2 and 150
      or coalesce(length(v_descricao),0)>1000
      or v_preco_centavos not between 0 and 100000000
      or v_quantidade_total not between 1 and 10000
      or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
      or (
        v_categoria_id is not null
        and not exists(
          select 1 from public.categorias_presentes
          where id=v_categoria_id and ativo
        )
      )
    then return false; end if;

    v_nome_normalizado:=lower(
      regexp_replace(trim(v_nome), '[[:space:]]+', ' ', 'g')
    );
    if not v_permitir_duplicado and exists (
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome), '[[:space:]]+', ' ', 'g'))
          = v_nome_normalizado
    ) then return false; end if;

    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(
      nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
    ) values(
      v_nome,v_descricao,v_preco_centavos,v_quantidade_total,v_ordem,
      v_categoria_id,v_imagens
    );
    return true;
  elsif p_acao='excluir' then
    v_id:=nullif(p_dados->>'id','')::uuid;
    update public.presentes set ativo=false
    where id=v_id and ativo;
    return found;
  end if;
  return false;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation or unique_violation
  then return false;
end $$;

revoke all on function public.importar_presentes_automatico(text,jsonb)
  from public;
revoke all on function public.administrar_presente_dashboard(text,text,jsonb)
  from public;
grant execute on function public.importar_presentes_automatico(text,jsonb)
  to anon,authenticated;
grant execute on function public.administrar_presente_dashboard(text,text,jsonb)
  to anon,authenticated;

notify pgrst,'reload schema';
commit;

-- ============================================================================
-- migration_037_edicao_presentes_entregas_ilimitados.sql
-- ============================================================================
begin;

-- Quantidade nula representa um presente que pode ser assinado sem limite.
alter table public.presentes
  alter column quantidade_total drop not null;

alter table public.presentes
  drop constraint if exists presentes_quantidade_total_check;

alter table public.presentes
  add constraint presentes_quantidade_total_check
  check (quantidade_total is null or quantidade_total between 1 and 10000);

-- Guarda o codigo efetivamente usado pelo presenteador e o recebimento fisico.
alter table public.reservas_presentes
  add column if not exists codigo_doador text,
  add column if not exists entregue_em timestamptz,
  add column if not exists entregue_por uuid references public.organizacao(id) on delete set null;

update public.reservas_presentes r
set codigo_doador=c.codigo
from public.convites c
where c.id=r.convite_id and r.codigo_doador is null;

alter table public.reservas_presentes
  drop constraint if exists reservas_presentes_codigo_doador_check;

alter table public.reservas_presentes
  add constraint reservas_presentes_codigo_doador_check
  check (codigo_doador is null or codigo_doador ~ '^[A-Z0-9]{6}$');

create index if not exists reservas_presentes_entrega_idx
  on public.reservas_presentes (entregue_em, criado_em desc)
  where meio='fisico' and status='confirmado';

create or replace function public.importar_presentes_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_item jsonb; v_nome text; v_categoria text; v_categoria_id uuid;
  v_descricao text; v_imagens text[]; v_valor numeric; v_quantidade integer;
  v_ordem integer; v_total integer:=0; v_permitir_duplicado boolean;
  v_nome_normalizado text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas)<>'array'
    or jsonb_array_length(p_linhas) not between 1 and 1000
  then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(coalesce(v_item->>'nome',''));
    v_categoria:=trim(coalesce(v_item->>'categoria',''));
    v_descricao:=nullif(trim(coalesce(v_item->>'descricao','')),'');
    v_valor:=(v_item->>'valor')::numeric;
    v_quantidade:=nullif(
      trim(coalesce(v_item->>'quantidade','')),
      ''
    )::integer;
    v_permitir_duplicado:=coalesce(
      (v_item->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value),'{}') into v_imagens
    from jsonb_array_elements_text(coalesce(v_item->'links_fotos','[]'::jsonb));

    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2
      or v_valor<0 or v_valor>1000000
      or (v_quantidade is not null and v_quantidade not between 1 and 10000)
      or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
    then return -2; end if;

    v_nome_normalizado:=lower(
      regexp_replace(trim(v_nome),'[[:space:]]+',' ','g')
    );
    if not v_permitir_duplicado and exists(
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome),'[[:space:]]+',' ','g'))
          =v_nome_normalizado
    ) then continue; end if;

    select id into v_categoria_id
    from public.categorias_presentes
    where lower(trim(nome))=lower(v_categoria)
    order by ativo desc,ordem
    limit 1;
    if v_categoria_id is null then
      select coalesce(max(ordem),0)+1 into v_ordem
      from public.categorias_presentes;
      insert into public.categorias_presentes(nome,ordem)
      values(v_categoria,v_ordem)
      returning id into v_categoria_id;
    else
      update public.categorias_presentes set ativo=true where id=v_categoria_id;
    end if;

    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(
      nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
    ) values(
      v_nome,v_descricao,round(v_valor*100)::integer,v_quantidade,
      v_ordem,v_categoria_id,v_imagens
    );
    v_total:=v_total+1;
  end loop;
  return v_total;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return -2;
end $$;

create or replace function public.administrar_presente_dashboard(
  p_token_hash text,
  p_acao text,
  p_dados jsonb
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid; v_nome text; v_descricao text; v_categoria_id uuid;
  v_preco_centavos integer; v_quantidade_total integer; v_imagens text[];
  v_ordem integer; v_permitir_duplicado boolean; v_nome_normalizado text;
  v_quantidade_usada integer;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;

  if p_acao in ('criar','editar') then
    if p_acao='editar' then
      v_id:=nullif(p_dados->>'id','')::uuid;
      if not exists(select 1 from public.presentes where id=v_id and ativo)
      then return false; end if;
    end if;

    v_nome:=trim(coalesce(p_dados->>'nome',''));
    v_descricao:=nullif(trim(coalesce(p_dados->>'descricao','')),'');
    v_categoria_id:=nullif(p_dados->>'categoria_id','')::uuid;
    v_preco_centavos:=(p_dados->>'preco_centavos')::integer;
    v_quantidade_total:=nullif(
      trim(coalesce(p_dados->>'quantidade_total','')),
      ''
    )::integer;
    v_permitir_duplicado:=coalesce(
      (p_dados->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value),'{}') into v_imagens
    from jsonb_array_elements_text(coalesce(p_dados->'imagens','[]'::jsonb));

    if length(v_nome) not between 2 and 150
      or coalesce(length(v_descricao),0)>1000
      or v_preco_centavos not between 0 and 100000000
      or (
        v_quantidade_total is not null
        and v_quantidade_total not between 1 and 10000
      )
      or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
      or (
        v_categoria_id is not null
        and not exists(
          select 1 from public.categorias_presentes
          where id=v_categoria_id and ativo
        )
      )
    then return false; end if;

    v_nome_normalizado:=lower(
      regexp_replace(trim(v_nome),'[[:space:]]+',' ','g')
    );
    if not v_permitir_duplicado and exists(
      select 1 from public.presentes p
      where p.ativo
        and (v_id is null or p.id<>v_id)
        and lower(regexp_replace(trim(p.nome),'[[:space:]]+',' ','g'))
          =v_nome_normalizado
    ) then return false; end if;

    if p_acao='criar' then
      select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
      insert into public.presentes(
        nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
      ) values(
        v_nome,v_descricao,v_preco_centavos,v_quantidade_total,v_ordem,
        v_categoria_id,v_imagens
      );
    else
      select coalesce(sum(quantidade),0)::integer into v_quantidade_usada
      from public.reservas_presentes
      where presente_id=v_id and status in ('pendente','confirmado');
      if v_quantidade_total is not null
        and v_quantidade_total<v_quantidade_usada
      then return false; end if;
      update public.presentes set
        nome=v_nome,
        descricao=v_descricao,
        preco_centavos=v_preco_centavos,
        quantidade_total=v_quantidade_total,
        categoria_id=v_categoria_id,
        imagens=v_imagens
      where id=v_id and ativo;
      if not found then return false; end if;
    end if;
    return true;
  elsif p_acao='excluir' then
    v_id:=nullif(p_dados->>'id','')::uuid;
    update public.presentes set ativo=false where id=v_id and ativo;
    return found;
  end if;
  return false;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation or unique_violation
  then return false;
end $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,
    'nome',p.nome,
    'descricao',p.descricao,
    'imagens',coalesce(p.imagens,'{}'),
    'categoria_id',p.categoria_id,
    'categoria',c.nome,
    'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,
    'quantidade_ilimitada',(p.quantidade_total is null),
    'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',case
      when p.quantidade_total is null then null
      else greatest(p.quantidade_total-coalesce(r.assinada,0),0)
    end
  ) order by c.ordem nulls last,p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join public.categorias_presentes c on c.id=p.categoria_id and c.ativo
  left join(
    select presente_id,sum(quantidade)::integer assinada
    from public.reservas_presentes
    where status in ('pendente','confirmado')
    group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo;
$$;

create or replace function public.registrar_presentes_fisicos(
  p_codigo text,
  p_itens jsonb,
  p_mensagem text default null
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_convite_id uuid; v_item jsonb; v_presente_id uuid;
  v_quantidade integer; v_usada integer; v_total integer;
  v_codigo text:=upper(trim(p_codigo));
begin
  select c.id into v_convite_id
  from public.convites c
  where c.ativo=true and (
    c.codigo=v_codigo or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id and g.codigo_individual=v_codigo
    )
  ) limit 1;
  if v_convite_id is null or jsonb_typeof(p_itens)<>'array'
    or jsonb_array_length(p_itens) not between 1 and 30
  then return false; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_presente_id:=(v_item->>'presente_id')::uuid;
    v_quantidade:=(v_item->>'quantidade')::integer;
    select quantidade_total into v_total
    from public.presentes
    where id=v_presente_id and ativo=true
    for update;
    if not found or v_quantidade not between 1 and 20 then return false; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada
    from public.reservas_presentes
    where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_total is not null and v_usada+v_quantidade>v_total
    then return false; end if;
    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,mensagem,codigo_doador
    ) values(
      v_convite_id,v_presente_id,v_quantidade,'confirmado','fisico',
      nullif(left(trim(p_mensagem),1000),''),v_codigo
    );
  end loop;
  return true;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return false;
end $$;

create or replace function public.alterar_presente_fisico(
  p_codigo text,
  p_reserva_id uuid,
  p_quantidade integer,
  p_cancelar boolean default false
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_reserva public.reservas_presentes%rowtype;
  v_usada integer; v_total integer;
begin
  select r.* into v_reserva
  from public.reservas_presentes r
  join public.convites c on c.id=r.convite_id
  where r.id=p_reserva_id and r.meio='fisico' and r.status='confirmado'
    and r.entregue_em is null and c.ativo=true and (
      c.codigo=upper(trim(p_codigo)) or exists(
        select 1 from public.convidados g
        where g.convite_id=c.id
          and g.codigo_individual=upper(trim(p_codigo))
      )
    )
  for update of r;
  if not found then return false; end if;
  if p_cancelar then
    update public.reservas_presentes
    set status='cancelado',atualizado_em=now()
    where id=p_reserva_id;
    return true;
  end if;
  if p_quantidade not between 1 and 20 then return false; end if;
  select quantidade_total into v_total
  from public.presentes
  where id=v_reserva.presente_id
  for update;
  select coalesce(sum(quantidade),0)::integer into v_usada
  from public.reservas_presentes
  where presente_id=v_reserva.presente_id
    and status in ('pendente','confirmado')
    and id<>p_reserva_id;
  if v_total is not null and v_usada+p_quantidade>v_total
  then return false; end if;
  update public.reservas_presentes
  set quantidade=p_quantidade,atualizado_em=now()
  where id=p_reserva_id;
  return true;
end $$;

create or replace function public.reservar_presentes_pagamento(
  p_codigo text,
  p_itens jsonb,
  p_preferencia_id text,
  p_external_reference text,
  p_checkout_url text,
  p_tentativa_pagamento_ate timestamptz,
  p_conciliacao_pagamento_ate timestamptz,
  p_doador_chave text,
  p_cpf_cifrado text,
  p_cpf_consentimento_em timestamptz,
  p_cpf_politica_versao text,
  p_mensagem text
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_convite_id uuid; v_item jsonb; v_presente_id uuid;
  v_quantidade integer; v_usada integer; v_total integer;
  v_codigo text:=upper(trim(p_codigo));
begin
  perform public.expirar_reservas_pagamento();
  select c.id into v_convite_id
  from public.convites c
  where c.ativo=true and (
    c.codigo=v_codigo or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id and g.codigo_individual=v_codigo
    )
  ) limit 1;
  if v_convite_id is null
    or jsonb_typeof(p_itens)<>'array'
    or jsonb_array_length(p_itens) not between 1 and 30
    or nullif(trim(p_preferencia_id),'') is null
    or nullif(trim(p_external_reference),'') is null
    or nullif(trim(p_checkout_url),'') is null
    or p_tentativa_pagamento_ate<=now()
    or p_conciliacao_pagamento_ate<=p_tentativa_pagamento_ate
  then return false; end if;

  for v_item in
    select value from jsonb_array_elements(p_itens)
    order by value->>'presente_id'
  loop
    v_presente_id:=(v_item->>'presente_id')::uuid;
    v_quantidade:=(v_item->>'quantidade')::integer;
    select quantidade_total into v_total
    from public.presentes
    where id=v_presente_id and ativo=true
    for update;
    if not found or v_quantidade not between 1 and 20
    then raise exception 'reserva_indisponivel'; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada
    from public.reservas_presentes
    where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_total is not null and v_usada+v_quantidade>v_total
    then raise exception 'reserva_indisponivel'; end if;
    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,preferencia_id,
      external_reference,pagamento_status,tentativa_pagamento_ate,
      conciliacao_pagamento_ate,checkout_url,doador_chave,cpf_cifrado,
      cpf_consentimento_em,cpf_politica_versao,mensagem,codigo_doador
    ) values(
      v_convite_id,v_presente_id,v_quantidade,'pendente','mercado_pago',
      p_preferencia_id,p_external_reference,'pending',p_tentativa_pagamento_ate,
      p_conciliacao_pagamento_ate,p_checkout_url,p_doador_chave,p_cpf_cifrado,
      p_cpf_consentimento_em,p_cpf_politica_versao,
      nullif(left(trim(p_mensagem),1000),''),v_codigo
    );
  end loop;
  return true;
exception
  when raise_exception or unique_violation or invalid_text_representation
    or not_null_violation or check_violation
  then return false;
end $$;

create or replace function public.listar_historico_presentes(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_resultado jsonb;
begin
  perform public.expirar_reservas_pagamento();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,
    'presente_id',r.presente_id,
    'presente',p.nome,
    'quantidade',r.quantidade,
    'meio',r.meio,
    'status',r.status,
    'status_entrega',case
      when r.meio='fisico' and r.entregue_em is not null then 'Entregue'
      when r.meio='fisico' and r.status='confirmado' then 'Assinado'
      else null
    end,
    'entregue_em',r.entregue_em,
    'pagamento_status',r.pagamento_status,
    'editavel',(
      r.meio='fisico' and r.status='confirmado' and r.entregue_em is null
    ),
    'pode_tentar_pagamento',(
      r.meio='mercado_pago' and r.status='pendente'
      and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
      and r.tentativa_pagamento_ate>now()
    ),
    'checkout_url',case
      when r.meio='mercado_pago' and r.status='pendente'
        and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
        and r.tentativa_pagamento_ate>now()
      then r.checkout_url else null
    end,
    'tentativa_pagamento_ate',r.tentativa_pagamento_ate,
    'conciliacao_pagamento_ate',r.conciliacao_pagamento_ate,
    'tipo_pagamento',r.tipo_pagamento,
    'boleto_vencimento',r.boleto_vencimento,
    'criado_em',r.criado_em,
    'aprovado_em',r.aprovado_em
  ) order by r.criado_em desc),'[]'::jsonb) into v_resultado
  from public.reservas_presentes r
  join public.presentes p on p.id=r.presente_id
  join public.convites c on c.id=r.convite_id
  where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id
        and g.codigo_individual=upper(trim(p_codigo))
    )
  );
  return v_resultado;
end $$;

create or replace function public.administrar_entrega_presente(
  p_token_hash text,
  p_reserva_id uuid,
  p_entregue boolean
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_organizacao_id uuid;
begin
  select o.id into v_organizacao_id
  from public.sessoes_organizacao s
  join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
    and (o.administrador or o.funcao in ('noivo','noiva'));
  if not found then return false; end if;
  update public.reservas_presentes set
    entregue_em=case when p_entregue then now() else null end,
    entregue_por=case when p_entregue then v_organizacao_id else null end,
    atualizado_em=now()
  where id=p_reserva_id and meio='fisico' and status='confirmado';
  return found;
end $$;

do $$
begin
  if to_regprocedure('public.dashboard_noivos_036(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_036;
  end if;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb
language sql
security definer
set search_path=public
as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'reservas',case when base->>'perfil'='assessoria' then '[]'::jsonb
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',r.id,
          'convidado',c.nome_familia,
          'codigo',coalesce(r.codigo_doador,c.codigo),
          'presente',p.nome,
          'quantidade',r.quantidade,
          'meio',r.meio,
          'status_entrega',case
            when r.meio='fisico' and r.entregue_em is not null then 'Entregue'
            when r.meio='fisico' then 'Assinado'
            else 'Pago'
          end,
          'entregue_em',r.entregue_em,
          'entregue_por_nome',o.nome,
          'criado_em',r.criado_em
        ) order by r.criado_em desc)
        from public.reservas_presentes r
        join public.convites c on c.id=r.convite_id
        join public.presentes p on p.id=r.presente_id
        left join public.organizacao o on o.id=r.entregue_por
        where r.status='confirmado'
      ),'[]'::jsonb) end
    ) end
  from(select public.dashboard_noivos_036(p_token_hash) base)x;
$$;

revoke all on function public.importar_presentes_automatico(text,jsonb) from public;
revoke all on function public.administrar_presente_dashboard(text,text,jsonb) from public;
revoke all on function public.registrar_presentes_fisicos(text,jsonb,text) from public;
revoke all on function public.alterar_presente_fisico(text,uuid,integer,boolean) from public;
revoke all on function public.reservar_presentes_pagamento(
  text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text
) from public;
revoke all on function public.listar_historico_presentes(text) from public;
revoke all on function public.administrar_entrega_presente(text,uuid,boolean) from public;
revoke all on function public.dashboard_noivos_036(text) from public;
revoke all on function public.dashboard_noivos_036(text) from anon,authenticated;
revoke all on function public.dashboard_noivos(text) from public;

grant execute on function public.importar_presentes_automatico(text,jsonb),
  public.administrar_presente_dashboard(text,text,jsonb),
  public.listar_presentes(),
  public.registrar_presentes_fisicos(text,jsonb,text),
  public.alterar_presente_fisico(text,uuid,integer,boolean),
  public.listar_historico_presentes(text),
  public.administrar_entrega_presente(text,uuid,boolean),
  public.dashboard_noivos(text)
to anon,authenticated;

grant execute on function public.reservar_presentes_pagamento(
  text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text
) to service_role;

notify pgrst,'reload schema';
commit;

-- migration_038_funcoes_individuais_manuais_criancas.sql
-- Privacidade das funções e manuais personalizados por convidado.
begin;

do $$
begin
  if to_regprocedure('public.buscar_convite_037(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_037;
  end if;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_resultado jsonb;
  v_convidados jsonb;
  v_responsaveis jsonb;
  v_pessoa jsonb;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_pode_gerenciar_criancas boolean := false;
begin
  select public.buscar_convite_037(p_codigo) into v_resultado;
  if v_resultado is null then return null; end if;

  if v_resultado->>'perfil_acesso' in ('noivos', 'assessoria', 'admin') then
    return v_resultado;
  end if;

  select item
    into v_pessoa
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb)) as x(item)
  where upper(trim(coalesce(item->>'codigo_individual', ''))) = v_codigo
  limit 1;

  v_pode_gerenciar_criancas :=
    coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
    and not coalesce((v_pessoa->>'crianca')::boolean, false);

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id'
          or (
            v_pode_gerenciar_criancas
            and coalesce((item->>'crianca')::boolean, false)
            and nullif(trim(coalesce(item->>'funcao', '')), '') is not null
          )
        then item || jsonb_build_object(
          'codigo_individual',
          case
            when coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
              or item->>'id' = v_pessoa->>'id'
            then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
        else item || jsonb_build_object(
          'funcao', null,
          'codigo_individual',
          case
            when coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
            then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_convidados
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb))
    with ordinality as x(item, ordem);

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id' then item
        else item || jsonb_build_object('funcao', null)
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_responsaveis
  from jsonb_array_elements(coalesce(v_resultado->'responsaveis', '[]'::jsonb))
    with ordinality as x(item, ordem);

  return v_resultado || jsonb_build_object(
    'funcao_cortejo', nullif(trim(coalesce(v_pessoa->>'funcao', '')), ''),
    'instrucoes_cortejo', '[]'::jsonb,
    'manuais', '[]'::jsonb,
    'pode_gerenciar', coalesce((v_pessoa->>'pode_gerenciar')::boolean, false),
    'convidados', v_convidados,
    'responsaveis', v_responsaveis
  );
end $$;

revoke all on function public.buscar_convite_037(text) from public;
revoke all on function public.buscar_convite_037(text) from anon, authenticated;
revoke all on function public.buscar_convite(text) from public;
grant execute on function public.buscar_convite(text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- migration_039_responsaveis_criancas_trajes.sql
-- Reconhece responsáveis por crianças do cortejo mesmo quando a classificação
-- etária ainda não foi marcada, usando também a função infantil cadastrada.
begin;

create or replace function public.funcao_cortejo_infantil(p_funcao text)
returns boolean
language sql
immutable
set search_path=public
as $$
  select case
    when nullif(trim(coalesce(p_funcao, '')), '') is null then false
    else (
      lower(translate(
        p_funcao,
        'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
        'AAAAEEIOOOUCaaaaeeiooouc'
      )) ~ '(porta.*(biblia|alianca)|pajem|pagen|pajen|daminha|florista|noivinh|crianca)'
    )
  end;
$$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_resultado jsonb;
  v_convidados jsonb;
  v_responsaveis jsonb;
  v_pessoa jsonb;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_pode_gerenciar_grupo boolean := false;
  v_pode_gerenciar_criancas boolean := false;
begin
  select public.buscar_convite_037(p_codigo) into v_resultado;
  if v_resultado is null then return null; end if;

  if v_resultado->>'perfil_acesso' in ('noivos', 'assessoria', 'admin') then
    return v_resultado;
  end if;

  select item
    into v_pessoa
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb)) as x(item)
  where upper(trim(coalesce(item->>'codigo_individual', ''))) = v_codigo
  limit 1;

  v_pode_gerenciar_grupo :=
    v_pessoa is not null
    and (
      coalesce((v_resultado->>'pode_gerenciar')::boolean, false)
      or coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
    );

  v_pode_gerenciar_criancas :=
    v_pode_gerenciar_grupo
    and not (
      coalesce((v_pessoa->>'crianca')::boolean, false)
      or public.funcao_cortejo_infantil(v_pessoa->>'funcao')
    );

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id'
          or (
            v_pode_gerenciar_criancas
            and (
              coalesce((item->>'crianca')::boolean, false)
              or public.funcao_cortejo_infantil(item->>'funcao')
            )
            and nullif(trim(coalesce(item->>'funcao', '')), '') is not null
          )
        then item || jsonb_build_object(
          'codigo_individual',
          case
            when v_pode_gerenciar_grupo or item->>'id' = v_pessoa->>'id'
            then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
        else item || jsonb_build_object(
          'funcao', null,
          'codigo_individual',
          case
            when v_pode_gerenciar_grupo then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_convidados
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb))
    with ordinality as x(item, ordem);

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id' then item
        else item || jsonb_build_object('funcao', null)
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_responsaveis
  from jsonb_array_elements(coalesce(v_resultado->'responsaveis', '[]'::jsonb))
    with ordinality as x(item, ordem);

  return v_resultado || jsonb_build_object(
    'funcao_cortejo', nullif(trim(coalesce(v_pessoa->>'funcao', '')), ''),
    'instrucoes_cortejo', '[]'::jsonb,
    'manuais', '[]'::jsonb,
    'pode_gerenciar', v_pode_gerenciar_grupo,
    'convidados', v_convidados,
    'responsaveis', v_responsaveis
  );
end $$;

revoke all on function public.funcao_cortejo_infantil(text) from public;
revoke all on function public.buscar_convite(text) from public;
grant execute on function public.buscar_convite(text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;
