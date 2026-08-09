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
