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
