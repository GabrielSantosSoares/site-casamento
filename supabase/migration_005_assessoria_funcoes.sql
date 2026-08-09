-- Perfis de acesso, funções individuais e confirmação pelo dashboard.
alter table public.convites add column if not exists perfil_acesso text not null default 'convidado'
  check (perfil_acesso in ('convidado','cortejo','noivos','assessoria','admin'));
alter table public.convidados add column if not exists funcao text;

update public.convites set perfil_acesso='noivos' where codigo in ('GABR26','ALAN26','GA2026');
update public.convites set perfil_acesso='cortejo' where nivel_acesso=2 and perfil_acesso='convidado';

insert into public.convites(codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,manuais,ativo)
values('ASSESS','Assessoria do Casamento','Assessora',3,'assessoria','{}',true)
on conflict(codigo) do update set nome_familia=excluded.nome_familia,
  funcao_cortejo=excluded.funcao_cortejo,nivel_acesso=3,perfil_acesso='assessoria',
  manuais='{}',senha_hash=null,ativo=true,atualizado_em=now();

insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
select id,'Assessora de teste',true,true,1,'Assessora' from public.convites c
where codigo='ASSESS' and not exists(select 1 from public.convidados g where g.convite_id=c.id);

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.convites%rowtype;
begin
  select * into v from public.convites where codigo=upper(trim(p_codigo)) and ativo=true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',v.codigo,'nome_familia',v.nome_familia,'funcao_cortejo',v.funcao_cortejo,
    'instrucoes_cortejo',v.instrucoes_cortejo,'nivel_acesso',v.nivel_acesso,
    'perfil_acesso',v.perfil_acesso,'manuais',v.manuais,'senha_criada',v.senha_hash is not null,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'funcao',coalesce(g.funcao,v.funcao_cortejo),'status',cf.status
    ) order by g.ordem,g.nome) from public.convidados g left join public.confirmacoes cf
      on cf.convidado_id=g.id where g.convite_id=v.id),'[]'::jsonb)
  );
end; $$;

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
      'status',coalesce(cf.status,'aguardando'),'codigo',c.codigo,'conjunto',c.nome_familia,
      'funcao',coalesce(g.funcao,c.funcao_cortejo),'nivel_acesso',c.nivel_acesso,
      'protegido',c.perfil_acesso='noivos'
    ) order by c.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites c on c.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id
    where c.perfil_acesso not in ('assessoria','admin')),'[]'::jsonb),
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

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_admin uuid; v_perfil text; v_convite_id uuid; v_alvo_perfil text; v_item jsonb; v_status text;
begin
  select s.convite_id,c.perfil_acesso into v_admin,v_perfil
  from public.sessoes_noivos s join public.convites c on c.id=s.convite_id
  where s.token_hash=p_token_hash and s.expira_em>now()
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_admin is null then return false; end if;
  if v_perfil='assessoria' and p_acao not in ('editar_restrito','presenca') then return false; end if;

  if p_acao in ('editar','editar_restrito','remover','presenca') then
    select c.id,c.perfil_acesso into v_convite_id,v_alvo_perfil
    from public.convidados g join public.convites c on c.id=g.convite_id
    where g.id=(p_dados->>'id')::uuid;
    if v_convite_id is null then return false; end if;
    if v_perfil='noivos' and v_alvo_perfil='noivos' then return false; end if;
  end if;

  if p_acao='adicionar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
    values(v_convite_id,trim(p_dados->>'nome'),coalesce((p_dados->>'principal')::boolean,false),
      coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
      nullif(trim(p_dados->>'funcao'),''));
  elsif p_acao='editar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    update public.convidados set convite_id=v_convite_id,nome=trim(p_dados->>'nome'),
      principal=coalesce((p_dados->>'principal')::boolean,false),
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      funcao=nullif(trim(p_dados->>'funcao'),'') where id=(p_dados->>'id')::uuid;
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
      on conflict(convite_id,convidado_id) do update set status=excluded.status,atualizado_em=now();
    else return false; end if;
  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
  elsif p_acao='importar' then
    for v_item in select * from jsonb_array_elements(p_dados->'linhas') loop
      insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo)
      values(upper(v_item->>'codigo'),trim(v_item->>'conjunto'),coalesce((v_item->>'nivel_acesso')::smallint,1),nullif(trim(v_item->>'funcao'),''))
      on conflict(codigo) do update set nome_familia=excluded.nome_familia,nivel_acesso=excluded.nivel_acesso;
      select id into v_convite_id from public.convites where codigo=upper(v_item->>'codigo');
      insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao)
      values(v_convite_id,trim(v_item->>'nome'),coalesce((v_item->>'principal')::boolean,false),
        coalesce((v_item->>'pode_gerenciar')::boolean,false),
        coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1),
        nullif(trim(v_item->>'funcao'),''));
    end loop;
  else return false; end if;
  return true;
end; $$;

grant execute on function public.dashboard_noivos(text) to anon,authenticated;
grant execute on function public.administrar_convidados(text,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
