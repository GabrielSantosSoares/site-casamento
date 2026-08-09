-- Grupos explícitos no dashboard e caixa de mensagens dos noivos.

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_perfil text;
begin
  select s.convite_id,c.perfil_acesso into v_convite_id,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_convite_id is null then return null; end if;
  return jsonb_build_object(
    'perfil',v_perfil,
    'convidados_total',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin')),
    'confirmados',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='sim' and c.perfil_acesso not in ('assessoria','admin')),
    'nao_comparecem',(select count(*) from public.confirmacoes cf join public.convidados g on g.id=cf.convidado_id join public.convites c on c.id=g.convite_id where cf.status='nao' and c.perfil_acesso not in ('assessoria','admin')),
    'aguardando',(select count(*) from public.convidados g join public.convites c on c.id=g.convite_id where c.perfil_acesso not in ('assessoria','admin') and not exists(select 1 from public.confirmacoes cf where cf.convidado_id=g.id)),
    'presentes_assinados',case when v_perfil='assessoria' then 0 else (select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado') end,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',c.codigo,
      'codigo_individual',g.codigo_individual,'conjunto',c.nome_familia,
      'funcao',coalesce(g.funcao,c.funcao_cortejo),'nivel_acesso',c.nivel_acesso,
      'protegido',c.perfil_acesso='noivos'
    ) order by c.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites c on c.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id
    where c.perfil_acesso not in ('assessoria','admin')),'[]'::jsonb),
    'grupos',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,'codigo',c.codigo,'titulo',c.nome_familia,
        'total',(select count(*) from public.convidados g where g.convite_id=c.id),
        'protegido',c.perfil_acesso='noivos'
      ) order by c.nome_familia)
      from public.convites c where c.ativo=true and c.perfil_acesso not in ('assessoria','admin')
    ),'[]'::jsonb) end,
    'mensagens',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'grupo',x.grupo,'codigo',x.codigo,'mensagem',x.mensagem,'atualizado_em',x.atualizado_em
      ) order by x.atualizado_em desc) from (
        select c.nome_familia grupo,c.codigo,cf.mensagem,max(cf.atualizado_em) atualizado_em
        from public.confirmacoes cf join public.convites c on c.id=cf.convite_id
        where nullif(trim(cf.mensagem),'') is not null
        group by cf.convite_id,c.nome_familia,c.codigo,cf.mensagem
        order by max(cf.atualizado_em) desc limit 200
      ) x
    ),'[]'::jsonb) end,
    'reservas',case when v_perfil='assessoria' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'convidado',c.nome_familia,
        'codigo',c.codigo,'presente',p.nome,'quantidade',r.quantidade,'criado_em',r.criado_em)
        order by r.criado_em desc)
      from public.reservas_presentes r join public.convites c on c.id=r.convite_id
      join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb) end,
    'ultimas_confirmacoes',coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (
      select g.nome,cf.status,cf.mensagem,cf.atualizado_em from public.confirmacoes cf
      join public.convidados g on g.id=cf.convidado_id order by cf.atualizado_em desc limit 8
    ) x),'[]'::jsonb)
  );
end; $$;

create or replace function public.administrar_grupos(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_perfil text; v_alvo public.convites%rowtype; v_codigo text; v_titulo text;
begin
  select c.perfil_acesso into v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','admin');
  if v_perfil is null then return false; end if;

  v_codigo:=upper(trim(coalesce(p_dados->>'codigo','')));
  v_titulo:=trim(coalesce(p_dados->>'titulo',''));
  if v_codigo !~ '^[A-Z0-9]{6}$' or length(v_titulo)<2 or length(v_titulo)>100 then return false; end if;

  if p_acao='criar' then
    if exists(select 1 from public.convites where codigo=v_codigo) then return false; end if;
    insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
    values(v_codigo,v_titulo,1,'convidado',true);
  elsif p_acao='editar' then
    select * into v_alvo from public.convites where id=(p_dados->>'id')::uuid;
    if not found or v_alvo.perfil_acesso in ('assessoria','admin') then return false; end if;
    if v_perfil='noivos' and v_alvo.perfil_acesso='noivos' then return false; end if;
    if exists(select 1 from public.convites where codigo=v_codigo and id<>v_alvo.id) then return false; end if;
    update public.convites set codigo=v_codigo,nome_familia=v_titulo,atualizado_em=now()
    where id=v_alvo.id;
  else return false; end if;
  return true;
exception when invalid_text_representation then return false;
end; $$;

revoke all on function public.administrar_grupos(text,text,jsonb) from public;
grant execute on function public.dashboard_noivos(text) to anon,authenticated;
grant execute on function public.administrar_grupos(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
