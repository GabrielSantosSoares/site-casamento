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
