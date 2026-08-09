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
