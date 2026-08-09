-- Dashboard detalhado, gestores de convites e administração dos convidados.
alter table public.convidados
  add column if not exists pode_gerenciar boolean not null default false;

update public.convidados set pode_gerenciar=true where principal=true;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite public.convites%rowtype;
begin
  select * into v_convite from public.convites where codigo=upper(trim(p_codigo)) and ativo=true;
  if not found then return null; end if;
  return jsonb_build_object(
    'codigo',v_convite.codigo,'nome_familia',v_convite.nome_familia,
    'funcao_cortejo',v_convite.funcao_cortejo,'instrucoes_cortejo',v_convite.instrucoes_cortejo,
    'nivel_acesso',v_convite.nivel_acesso,'manuais',v_convite.manuais,
    'senha_criada',v_convite.senha_hash is not null,
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,'status',c.status
    ) order by g.ordem,g.nome) from public.convidados g
    left join public.confirmacoes c on c.convidado_id=g.id and c.convite_id=v_convite.id
    where g.convite_id=v_convite.id),'[]'::jsonb)
  );
end; $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  select convite_id into v_convite_id from public.sessoes_noivos
  where token_hash=p_token_hash and expira_em>now();
  if v_convite_id is null then return null; end if;
  return jsonb_build_object(
    'convidados_total',(select count(*) from public.convidados),
    'confirmados',(select count(*) from public.confirmacoes where status='sim'),
    'nao_comparecem',(select count(*) from public.confirmacoes where status='nao'),
    'aguardando',(select count(*) from public.convidados g where not exists(select 1 from public.confirmacoes c where c.convidado_id=g.id)),
    'presentes_assinados',(select coalesce(sum(quantidade),0) from public.reservas_presentes where status='confirmado'),
    'convidados',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'nome',g.nome,'principal',g.principal,'pode_gerenciar',g.pode_gerenciar,
      'status',coalesce(cf.status,'aguardando'),'codigo',cv.codigo,'conjunto',cv.nome_familia,
      'funcao',cv.funcao_cortejo,'nivel_acesso',cv.nivel_acesso
    ) order by cv.nome_familia,g.ordem,g.nome)
    from public.convidados g join public.convites cv on cv.id=g.convite_id
    left join public.confirmacoes cf on cf.convidado_id=g.id),'[]'::jsonb),
    'reservas',coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'convidado',cv.nome_familia,'codigo',cv.codigo,'presente',p.nome,
      'quantidade',r.quantidade,'criado_em',r.criado_em
    ) order by r.criado_em desc)
    from public.reservas_presentes r join public.convites cv on cv.id=r.convite_id
    join public.presentes p on p.id=r.presente_id where r.status='confirmado'),'[]'::jsonb),
    'ultimas_confirmacoes',coalesce((select jsonb_agg(x order by x.atualizado_em desc) from (
      select g.nome,c.status,c.mensagem,c.atualizado_em from public.confirmacoes c
      join public.convidados g on g.id=c.convidado_id order by c.atualizado_em desc limit 8
    ) x),'[]'::jsonb)
  );
end; $$;

create or replace function public.administrar_convidados(
  p_token_hash text,p_acao text,p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_admin uuid; v_convite_id uuid; v_item jsonb;
begin
  select convite_id into v_admin from public.sessoes_noivos
  where token_hash=p_token_hash and expira_em>now();
  if v_admin is null then return false; end if;

  if p_acao='adicionar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    if v_convite_id is null then return false; end if;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem)
    values(v_convite_id,trim(p_dados->>'nome'),coalesce((p_dados->>'principal')::boolean,false),
      coalesce((p_dados->>'pode_gerenciar')::boolean,false),
      coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1));
  elsif p_acao='editar' then
    select id into v_convite_id from public.convites where codigo=upper(p_dados->>'codigo');
    if v_convite_id is null then return false; end if;
    update public.convidados set convite_id=v_convite_id,nome=trim(p_dados->>'nome'),
      principal=coalesce((p_dados->>'principal')::boolean,false),
      pode_gerenciar=coalesce((p_dados->>'pode_gerenciar')::boolean,false)
    where id=(p_dados->>'id')::uuid;
  elsif p_acao='remover' then
    delete from public.convidados where id=(p_dados->>'id')::uuid;
  elsif p_acao='criar_conjunto' then
    insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo,manuais)
    values(upper(p_dados->>'codigo'),trim(p_dados->>'conjunto'),
      coalesce((p_dados->>'nivel_acesso')::smallint,1),nullif(trim(p_dados->>'funcao'),''),
      coalesce(array(select jsonb_array_elements_text(p_dados->'manuais')),'{}'))
    on conflict(codigo) do update set nome_familia=excluded.nome_familia,
      nivel_acesso=excluded.nivel_acesso,funcao_cortejo=excluded.funcao_cortejo,
      manuais=excluded.manuais,atualizado_em=now();
  elsif p_acao='importar' then
    for v_item in select * from jsonb_array_elements(p_dados->'linhas') loop
      insert into public.convites(codigo,nome_familia,nivel_acesso,funcao_cortejo)
      values(upper(v_item->>'codigo'),trim(v_item->>'conjunto'),
        coalesce((v_item->>'nivel_acesso')::smallint,1),nullif(trim(v_item->>'funcao'),''))
      on conflict(codigo) do update set nome_familia=excluded.nome_familia,
        nivel_acesso=excluded.nivel_acesso,funcao_cortejo=excluded.funcao_cortejo;
      select id into v_convite_id from public.convites where codigo=upper(v_item->>'codigo');
      insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem)
      values(v_convite_id,trim(v_item->>'nome'),
        coalesce((v_item->>'principal')::boolean,false),
        coalesce((v_item->>'pode_gerenciar')::boolean,false),
        coalesce((select max(ordem)+1 from public.convidados where convite_id=v_convite_id),1));
    end loop;
  else return false;
  end if;
  return true;
end; $$;

revoke all on function public.administrar_convidados(text,text,jsonb) from public;
grant execute on function public.administrar_convidados(text,text,jsonb) to anon,authenticated;
grant execute on function public.dashboard_noivos(text) to anon,authenticated;
notify pgrst,'reload schema';
