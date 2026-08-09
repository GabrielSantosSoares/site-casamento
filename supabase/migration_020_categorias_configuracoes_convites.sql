-- Categorias editáveis, configurações gerais, URLs dos convites e suporte à exportação.

create table if not exists public.categorias_presentes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  ordem integer not null default 0,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

insert into public.categorias_presentes (nome, ordem)
values
  ('Sala', 1),
  ('Cozinha', 2),
  ('Quarto', 3),
  ('Banheiro', 4),
  ('Viagem', 5)
on conflict (nome) do nothing;

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
