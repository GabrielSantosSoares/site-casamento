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
