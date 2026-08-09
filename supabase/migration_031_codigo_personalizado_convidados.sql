begin;

create or replace function public.administrar_convidado_com_codigo(
  p_token_hash text, p_acao text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo_individual','')));
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
    or v_codigo !~ '^[A-Z0-9]{6}$'
    or length(v_nome) not between 2 and 150
    or v_origem not in ('noivo','noiva','ambos','nao_classificado')
    or not exists (
      select 1 from public.sessoes_organizacao s
      join public.organizacao o on o.id=s.organizacao_id
      where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
        and (o.administrador or o.funcao in ('noivo','noiva'))
    ) then return false; end if;

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

  select id into v_convite_destino from public.convites where codigo=upper(trim(p_dados->>'codigo'));
  if v_convite_destino is null then return false; end if;
  update public.confirmacoes set convite_id=v_convite_destino where convidado_id=v_id;
  update public.convidados set convite_id=v_convite_destino,nome=v_nome,principal=false,
    pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),funcao=v_funcao,
    codigo_individual=v_codigo,origem=v_origem,
    crianca=coalesce((p_dados->>'crianca')::boolean,crianca) where id=v_id;
  if v_grupo_individual and v_convite_atual=v_convite_destino then
    update public.convites set codigo=v_codigo where id=v_convite_atual and codigo=v_codigo_antigo;
  elsif v_grupo_individual then
    delete from public.convites c where c.id=v_convite_atual
      and not exists(select 1 from public.convidados g where g.convite_id=c.id)
      and not exists(select 1 from public.reservas_presentes r where r.convite_id=c.id);
  end if;
  return found;
exception when unique_violation or invalid_text_representation or not_null_violation then
  return false;
end $$;

revoke all on function public.administrar_convidado_com_codigo(text,text,jsonb) from public;
grant execute on function public.administrar_convidado_com_codigo(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
