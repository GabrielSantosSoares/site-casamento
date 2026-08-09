-- Códigos personalizados da organização e login unificado por usuário ou código.
-- Execute depois da migration_033_revisao_geral_perfis_notificacoes.sql.

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
