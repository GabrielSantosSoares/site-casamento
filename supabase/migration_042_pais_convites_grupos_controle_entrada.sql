-- Perfis dos pais, gestão de grupos, controle de entrada e permissões da organização.
-- Pode ser executada depois da migration 040 ou 041; todas as alterações são idempotentes.
begin;

alter table public.organizacao
  drop constraint if exists organizacao_funcao_check;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.organizacao'::regclass
      and conname='organizacao_funcao_valida_check'
  ) then
    alter table public.organizacao
      add constraint organizacao_funcao_valida_check
      check (length(trim(funcao)) between 2 and 80);
  end if;
end $$;

alter table public.convidados
  add column if not exists chegada_confirmada_em timestamptz,
  add column if not exists chegada_confirmada_por uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.convidados'::regclass
      and conname='convidados_chegada_confirmada_por_fkey'
  ) then
    alter table public.convidados
      add constraint convidados_chegada_confirmada_por_fkey
      foreign key (chegada_confirmada_por)
      references public.organizacao(id) on delete set null;
  end if;
end $$;

create index if not exists convidados_chegada_confirmada_idx
  on public.convidados (chegada_confirmada_em desc)
  where chegada_confirmada_em is not null;

create or replace function public.eh_gestor_organizacao(p_funcao text)
returns boolean
language sql
immutable
set search_path=public
as $$
  select lower(translate(trim(coalesce(p_funcao,'')),
    'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc')) in (
      'administrador','administradora','admin',
      'noivo','noiva','assessoria','assessor','assessora',
      'pai do noivo','mae do noivo','pai da noiva','mae da noiva'
    );
$$;

create or replace function public.eh_administrador_convidados(p_funcao text)
returns boolean
language sql
immutable
set search_path=public
as $$
  select lower(translate(trim(coalesce(p_funcao,'')),
    'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc')) in (
      'noivo','noiva',
      'pai do noivo','mae do noivo','pai da noiva','mae da noiva'
    );
$$;

create or replace function public.tem_acesso_lista(p_token_hash text)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select exists(
    select 1
    from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or public.eh_administrador_convidados(o.funcao))
  );
$$;

create or replace function public.administrar_organizacao_backend(
  p_token_hash text, p_acao text, p_dados jsonb, p_hash text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_ator public.organizacao%rowtype;
  v_alvo public.organizacao%rowtype;
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo','')));
  v_usuario text := lower(trim(coalesce(p_dados->>'usuario','')));
  v_nome text := trim(coalesce(p_dados->>'nome',''));
  v_funcao text := trim(coalesce(p_dados->>'funcao',''));
  v_funcao_normalizada text;
  v_administrador boolean := false;
  v_alvo_protegido boolean := false;
begin
  select o.* into v_ator
  from public.sessoes_organizacao s
  join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;

  if not found or not (v_ator.administrador or public.eh_gestor_organizacao(v_ator.funcao)) then
    return jsonb_build_object('ok',false,'motivo','acesso_negado');
  end if;

  v_funcao_normalizada:=lower(translate(v_funcao,
    'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc'));
  v_administrador:=v_ator.administrador and (
    coalesce((p_dados->>'administrador')::boolean,false)
    or v_funcao_normalizada in ('administrador','administradora','admin')
  );

  if p_acao='criar' then
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or length(v_funcao) not between 2 and 80
      or p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
      or (
        not v_ator.administrador
        and v_funcao_normalizada in (
          'administrador','administradora','admin','noivo','noiva'
        )
      )
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

  v_alvo_protegido:=
    v_alvo.administrador
    or lower(translate(trim(v_alvo.funcao),
      'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
      'AAAAEEIOOOUCaaaaeeiooouc')) in (
        'administrador','administradora','admin','noivo','noiva'
      );
  if not v_ator.administrador and v_alvo_protegido then
    return jsonb_build_object('ok',false,'motivo','acesso_negado');
  end if;

  if p_acao='editar' then
    if v_usuario='admin' or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or length(v_funcao) not between 2 and 80
      or v_codigo !~ '^[A-Z0-9]{6}$'
      or (
        not v_ator.administrador
        and v_funcao_normalizada in (
          'administrador','administradora','admin','noivo','noiva'
        )
      )
    then
      return jsonb_build_object('ok',false,'motivo','dados_invalidos');
    end if;
    perform pg_advisory_xact_lock(hashtext(v_codigo));
    if exists(select 1 from public.organizacao where lower(usuario)=v_usuario and id<>v_alvo.id) then
      return jsonb_build_object('ok',false,'motivo','usuario_indisponivel');
    end if;
    if exists(select 1 from public.organizacao where codigo=v_codigo and id<>v_alvo.id)
      or exists(select 1 from public.convites where codigo=v_codigo)
      or exists(select 1 from public.convidados where codigo_individual=v_codigo)
    then
      return jsonb_build_object('ok',false,'motivo','codigo_indisponivel');
    end if;
    update public.organizacao set
      nome=v_nome,usuario=v_usuario,codigo=v_codigo,funcao=v_funcao,
      administrador=v_administrador,atualizado_em=now()
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
  elsif p_acao='apagar' then
    delete from public.organizacao where id=v_alvo.id;
    return jsonb_build_object('ok',true);
  end if;

  return jsonb_build_object('ok',false,'motivo','dados_invalidos');
exception
  when unique_violation then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
  when invalid_text_representation or check_violation or not_null_violation then
    return jsonb_build_object('ok',false,'motivo','dados_invalidos');
end $$;

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
        and (o.administrador or public.eh_administrador_convidados(o.funcao))
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
  return true;
exception
  when unique_violation or invalid_text_representation or not_null_violation then
    return false;
end $$;

create or replace function public.administrar_origem_convidado(
  p_token_hash text,p_convidado_id uuid,p_origem text
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_origem not in ('noivo','noiva','ambos','nao_classificado')
    or not public.tem_acesso_lista(p_token_hash)
  then return false; end if;
  update public.convidados set origem=p_origem where id=p_convidado_id;
  return found;
end $$;

create or replace function public.configurar_criancas_grupo(
  p_token_hash text,p_codigo text,p_limite integer
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if p_limite not between 0 and 20
    or not public.tem_acesso_lista(p_token_hash)
  then return false; end if;
  update public.convites
  set criancas_adicionais_limite=p_limite,atualizado_em=now()
  where codigo=upper(trim(p_codigo)) and ativo and perfil_acesso='convidado';
  return found;
end $$;

create or replace function public.remover_convidado_organizacao(
  p_token_hash text,p_convidado_id uuid
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_convite_id uuid;
begin
  if not public.tem_acesso_lista(p_token_hash) then return false; end if;
  select convite_id into v_convite_id
  from public.convidados where id=p_convidado_id;
  if v_convite_id is null then return false; end if;
  delete from public.convidados where id=p_convidado_id;
  if not found then return false; end if;
  delete from public.convites c
  where c.id=v_convite_id and c.perfil_acesso='convidado'
    and not exists(select 1 from public.convidados g where g.convite_id=c.id)
    and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
  update public.convidados
  set pode_gerenciar=true
  where id=(
    select g.id from public.convidados g
    where g.convite_id=v_convite_id
    order by g.principal desc,g.ordem,g.nome
    limit 1
  )
    and not exists(
      select 1 from public.convidados gestor
      where gestor.convite_id=v_convite_id and gestor.pode_gerenciar
    );
  return true;
end $$;

create or replace function public.listar_organizacao_gestores(p_token_hash text)
returns jsonb
language sql
security definer
stable
set search_path=public
as $$
  select case when exists(
    select 1
    from public.sessoes_organizacao s
    join public.organizacao ator on ator.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and ator.ativo
      and (ator.administrador or public.eh_gestor_organizacao(ator.funcao))
  ) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',o.id,'nome',o.nome,'usuario',o.usuario,'codigo',o.codigo,
      'funcao',o.funcao,'administrador',o.administrador,
      'principal',o.principal,'senha_criada',o.senha_hash is not null,
      'exige_troca_senha',o.exige_troca_senha
    ) order by o.principal desc,o.nome)
    from public.organizacao o where o.ativo
  ),'[]'::jsonb) else null end;
$$;

create or replace function public.listar_grupos_gestores(p_token_hash text)
returns jsonb
language sql
security definer
stable
set search_path=public
as $$
  select case when public.tem_acesso_lista(p_token_hash) then coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',c.id,'codigo',c.codigo,'titulo',c.nome_familia,
      'total',(select count(*) from public.convidados g where g.convite_id=c.id),
      'protegido',false,
      'criancas_adicionais_limite',c.criancas_adicionais_limite,
      'criancas_adicionais_usadas',(
        select count(*) from public.convidados g
        where g.convite_id=c.id and g.adicionado_pelo_responsavel
      )
    ) order by c.nome_familia,c.codigo)
    from public.convites c
    where c.ativo and c.perfil_acesso='convidado'
  ),'[]'::jsonb) else null end;
$$;


create or replace function public.administrar_grupos(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_alvo public.convites%rowtype;
  v_pessoa public.convidados%rowtype;
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo','')));
  v_titulo text := trim(coalesce(p_dados->>'titulo',''));
  v_origem uuid;
  v_destino uuid;
  v_ordem smallint;
begin
  if not public.tem_acesso_lista(p_token_hash) then return false; end if;

  if p_acao='associar_pessoa' then
    select * into v_alvo from public.convites
    where id=nullif(p_dados->>'id','')::uuid and ativo and perfil_acesso='convidado';
    select * into v_pessoa from public.convidados
    where id=nullif(p_dados->>'convidado_id','')::uuid;
    if v_alvo.id is null or v_pessoa.id is null then return false; end if;
    if v_pessoa.convite_id=v_alvo.id then return true; end if;
    v_origem:=v_pessoa.convite_id;
    select coalesce(max(ordem),0)+1 into v_ordem
    from public.convidados where convite_id=v_alvo.id;
    update public.confirmacoes set convite_id=v_alvo.id
    where convidado_id=v_pessoa.id;
    update public.convidados set
      convite_id=v_alvo.id,ordem=v_ordem,principal=false
    where id=v_pessoa.id;
    if not exists(select 1 from public.convidados where convite_id=v_alvo.id and pode_gerenciar) then
      update public.convidados set pode_gerenciar=true where id=v_pessoa.id;
    end if;
    update public.convidados set pode_gerenciar=true
    where id=(
      select g.id from public.convidados g
      where g.convite_id=v_origem
      order by g.principal desc,g.ordem,g.nome
      limit 1
    ) and not exists(
      select 1 from public.convidados gestor
      where gestor.convite_id=v_origem and gestor.pode_gerenciar
    );
    delete from public.convites c
    where c.id=v_origem and c.perfil_acesso='convidado'
      and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    return true;
  elsif p_acao='tornar_individual' then
    select * into v_pessoa from public.convidados
    where id=nullif(p_dados->>'convidado_id','')::uuid;
    if v_pessoa.id is null then return false; end if;
    v_origem:=v_pessoa.convite_id;
    select id into v_destino from public.convites
    where codigo=v_pessoa.codigo_individual;
    if v_destino=v_origem then return true; end if;
    if v_destino is not null then return false; end if;
    insert into public.convites(
      codigo,nome_familia,nivel_acesso,perfil_acesso,ativo
    ) values(
      v_pessoa.codigo_individual,v_pessoa.nome,1,'convidado',true
    ) returning id into v_destino;
    update public.confirmacoes set convite_id=v_destino
    where convidado_id=v_pessoa.id;
    update public.convidados set
      convite_id=v_destino,principal=true,pode_gerenciar=true,ordem=1
    where id=v_pessoa.id;
    update public.convidados set pode_gerenciar=true
    where id=(
      select g.id from public.convidados g
      where g.convite_id=v_origem
      order by g.principal desc,g.ordem,g.nome
      limit 1
    ) and not exists(
      select 1 from public.convidados gestor
      where gestor.convite_id=v_origem and gestor.pode_gerenciar
    );
    delete from public.convites c
    where c.id=v_origem and c.perfil_acesso='convidado'
      and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
    return true;
  end if;

  if v_codigo !~ '^[A-Z0-9]{6}$' or length(v_titulo) not between 2 and 100
    or exists(select 1 from public.organizacao where codigo=v_codigo)
  then return false; end if;

  if p_acao='criar' then
    if exists(select 1 from public.convites where codigo=v_codigo)
      or exists(select 1 from public.convidados where codigo_individual=v_codigo)
    then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_titulo,1,'convidado',true);
  elsif p_acao='editar' then
    select * into v_alvo from public.convites where id=nullif(p_dados->>'id','')::uuid;
    if not found
      or exists(select 1 from public.convites where codigo=v_codigo and id<>v_alvo.id)
      or exists(
        select 1 from public.convidados
        where codigo_individual=v_codigo and convite_id<>v_alvo.id
      )
    then return false; end if;
    update public.convites set codigo=v_codigo,nome_familia=v_titulo,atualizado_em=now()
    where id=v_alvo.id;
  else
    return false;
  end if;
  return true;
exception
  when invalid_text_representation or unique_violation or check_violation or not_null_violation then
    return false;
end $$;

create or replace function public.buscar_controle_entrada(
  p_token_hash text,p_codigo text
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_resultado jsonb;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
  ) then return null; end if;

  select jsonb_build_object(
    'id',g.id,'nome',g.nome,'codigo_individual',g.codigo_individual,
    'grupo',c.nome_familia,'funcao',g.funcao,'resposta',cf.status,
    'chegada_confirmada_em',g.chegada_confirmada_em,
    'chegada_confirmada_por_nome',o.nome
  ) into v_resultado
  from public.convidados g
  join public.convites c on c.id=g.convite_id and c.ativo
  left join public.confirmacoes cf on cf.convidado_id=g.id
  left join public.organizacao o on o.id=g.chegada_confirmada_por
  where g.codigo_individual=upper(trim(p_codigo))
  limit 1;
  return v_resultado;
end $$;

create or replace function public.confirmar_chegada_convidado(
  p_token_hash text,p_convidado_id uuid
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
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo;
  if v_organizacao_id is null then return false; end if;
  update public.convidados g set
    chegada_confirmada_em=now(),chegada_confirmada_por=v_organizacao_id
  from public.convites c
  where g.id=p_convidado_id and c.id=g.convite_id and c.ativo;
  return found;
end $$;

create or replace function public.controle_entrada_resumo(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
  ) then return null; end if;

  return jsonb_build_object(
    'confirmados',(
      select count(*) from public.convidados g
      join public.convites c on c.id=g.convite_id and c.ativo
      join public.confirmacoes cf on cf.convidado_id=g.id and cf.status='sim'
    ),
    'presentes',(
      select count(*) from public.convidados g
      join public.convites c on c.id=g.convite_id and c.ativo
      where g.chegada_confirmada_em is not null
    ),
    'faltantes',(
      select count(*) from public.convidados g
      join public.convites c on c.id=g.convite_id and c.ativo
      join public.confirmacoes cf on cf.convidado_id=g.id and cf.status='sim'
      where g.chegada_confirmada_em is null
    ),
    'presentes_lista',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',g.id,'nome',g.nome,'codigo_individual',g.codigo_individual,
        'grupo',c.nome_familia,'funcao',g.funcao,'resposta',cf.status,
        'chegada_confirmada_em',g.chegada_confirmada_em,
        'chegada_confirmada_por_nome',o.nome
      ) order by g.chegada_confirmada_em desc,g.nome)
      from public.convidados g
      join public.convites c on c.id=g.convite_id and c.ativo
      left join public.confirmacoes cf on cf.convidado_id=g.id
      left join public.organizacao o on o.id=g.chegada_confirmada_por
      where g.chegada_confirmada_em is not null
    ),'[]'::jsonb),
    'faltantes_lista',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',g.id,'nome',g.nome,'codigo_individual',g.codigo_individual,
        'grupo',c.nome_familia,'funcao',g.funcao,'resposta',cf.status,
        'chegada_confirmada_em',g.chegada_confirmada_em,
        'chegada_confirmada_por_nome',null
      ) order by g.nome)
      from public.convidados g
      join public.convites c on c.id=g.convite_id and c.ativo
      join public.confirmacoes cf on cf.convidado_id=g.id and cf.status='sim'
      where g.chegada_confirmada_em is null
    ),'[]'::jsonb)
  );
end $$;

revoke all on function public.eh_gestor_organizacao(text) from public;
revoke all on function public.eh_administrador_convidados(text) from public;
revoke all on function public.tem_acesso_lista(text) from public;
revoke all on function public.administrar_organizacao_backend(text,text,jsonb,text)
  from public,anon,authenticated;
revoke all on function public.administrar_convidado_com_codigo(text,text,jsonb) from public;
revoke all on function public.administrar_origem_convidado(text,uuid,text) from public;
revoke all on function public.configurar_criancas_grupo(text,text,integer) from public;
revoke all on function public.remover_convidado_organizacao(text,uuid) from public;
revoke all on function public.listar_organizacao_gestores(text) from public;
revoke all on function public.listar_grupos_gestores(text) from public;
revoke all on function public.administrar_grupos(text,text,jsonb) from public;
revoke all on function public.buscar_controle_entrada(text,text) from public;
revoke all on function public.confirmar_chegada_convidado(text,uuid) from public;
revoke all on function public.controle_entrada_resumo(text) from public;

grant execute on function public.administrar_organizacao_backend(text,text,jsonb,text)
  to service_role;
grant execute on function public.administrar_grupos(text,text,jsonb),
  public.administrar_convidado_com_codigo(text,text,jsonb),
  public.administrar_origem_convidado(text,uuid,text),
  public.configurar_criancas_grupo(text,text,integer),
  public.remover_convidado_organizacao(text,uuid),
  public.listar_organizacao_gestores(text),
  public.listar_grupos_gestores(text),
  public.buscar_controle_entrada(text,text),
  public.confirmar_chegada_convidado(text,uuid),
  public.controle_entrada_resumo(text)
to anon,authenticated;

notify pgrst,'reload schema';
commit;
