begin;

alter table public.convidados add column if not exists visualizado_em timestamptz;
alter table public.reservas_presentes add column if not exists mensagem text;

do $$ begin
  if to_regprocedure('public.buscar_convite_027(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_027;
  end if;
  if to_regprocedure('public.dashboard_noivos_027(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_027;
  end if;
exception when undefined_function then null;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_resultado jsonb;
begin
  update public.convidados
     set visualizado_em=coalesce(visualizado_em,now())
   where codigo_individual=upper(trim(p_codigo));
  select public.buscar_convite_027(p_codigo) into v_resultado;
  return v_resultado;
end $$;

drop function if exists public.registrar_presentes_fisicos(text,jsonb);
create function public.registrar_presentes_fisicos(p_codigo text,p_itens jsonb,p_mensagem text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_item jsonb; v_presente_id uuid; v_quantidade integer; v_usada integer;
begin
  select c.id into v_convite_id from public.convites c where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo)))
  ) limit 1;
  if v_convite_id is null or jsonb_typeof(p_itens)<>'array' or jsonb_array_length(p_itens)=0 then return false; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_presente_id=(v_item->>'presente_id')::uuid; v_quantidade=(v_item->>'quantidade')::integer;
    perform 1 from public.presentes where id=v_presente_id and ativo=true for update;
    if not found or v_quantidade<1 then return false; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada from public.reservas_presentes where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_usada+v_quantidade>(select quantidade_total from public.presentes where id=v_presente_id) then return false; end if;
    insert into public.reservas_presentes(convite_id,presente_id,quantidade,status,meio,mensagem)
    values(v_convite_id,v_presente_id,v_quantidade,'confirmado','fisico',nullif(left(trim(p_mensagem),1000),''));
  end loop;
  return true;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    (base - 'mensagens') || jsonb_build_object(
      'convidados',coalesce((select jsonb_agg(item || jsonb_build_object('visualizado_em',g.visualizado_em)) from jsonb_array_elements(coalesce(base->'convidados','[]'::jsonb)) item left join public.convidados g on g.id=(item->>'id')::uuid),'[]'::jsonb),
      'mensagens',case when base->>'perfil'='assessoria' then '[]'::jsonb else coalesce((
        select jsonb_agg(m order by m.atualizado_em desc) from (
          select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em
          from public.confirmacoes cf join public.convites c on c.id=cf.convite_id
          where nullif(trim(cf.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,cf.mensagem
          union all
          select c.nome_familia,c.codigo,r.mensagem,max(r.criado_em)
          from public.reservas_presentes r join public.convites c on c.id=r.convite_id
          where nullif(trim(r.mensagem),'') is not null group by c.id,c.nome_familia,c.codigo,r.mensagem
        ) m
      ),'[]'::jsonb) end,
      'notificacoes',case when base->>'perfil'='assessoria' then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('grupo',c.nome_familia,'codigo',c.codigo,'mensagem',n.mensagem,'criado_em',n.criado_em) order by n.criado_em desc) from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id),'[]'::jsonb) end
    ) end
  from (select public.dashboard_noivos_027(p_token_hash) base) x;
$$;

revoke all on function public.buscar_convite(text),public.registrar_presentes_fisicos(text,jsonb,text),public.dashboard_noivos(text) from public;
grant execute on function public.buscar_convite(text),public.registrar_presentes_fisicos(text,jsonb,text),public.dashboard_noivos(text) to anon,authenticated;

notify pgrst,'reload schema';
commit;
