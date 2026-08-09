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
