-- Confirmações após o prazo, notificações e dados editáveis do evento.

alter table public.configuracao_evento
  add column if not exists data_evento date not null default date '2026-10-03',
  add column if not exists hora_evento time not null default time '18:30',
  add column if not exists cidade text not null default 'Candeias-BA',
  add column if not exists local_liberado boolean not null default false,
  add column if not exists nome_espaco text not null default 'Espaço Brunus',
  add column if not exists endereco text not null
    default 'Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000',
  add column if not exists link_maps text;

create table if not exists public.notificacoes_organizacao (
  id uuid primary key default gen_random_uuid(),
  convite_id uuid not null references public.convites(id) on delete cascade,
  convidado_id uuid references public.convidados(id) on delete set null,
  tipo text not null default 'alteracao_status',
  status_anterior text,
  status_novo text not null,
  mensagem text not null,
  criado_em timestamptz not null default now()
);

alter table public.notificacoes_organizacao enable row level security;
revoke all on public.notificacoes_organizacao from anon, authenticated;

create or replace function public.registrar_notificacao_status(
  p_convite_id uuid,
  p_convidado_id uuid,
  p_anterior text,
  p_novo text,
  p_origem text
) returns void
language plpgsql security definer set search_path=public as $$
declare v_nome text; v_grupo text;
begin
  if p_anterior is not distinct from p_novo then return; end if;
  select g.nome,c.nome_familia into v_nome,v_grupo
  from public.convidados g join public.convites c on c.id=g.convite_id
  where g.id=p_convidado_id and c.id=p_convite_id;
  insert into public.notificacoes_organizacao(
    convite_id,convidado_id,status_anterior,status_novo,mensagem
  ) values(
    p_convite_id,p_convidado_id,p_anterior,p_novo,
    coalesce(v_nome,'Convidado')||' ('||coalesce(v_grupo,'grupo')||') alterou o status de '||
    coalesce(p_anterior,'aguardando')||' para '||p_novo||' via '||p_origem||'.'
  );
end $$;

create or replace function public.administrar_configuracao_evento(
  p_token_hash text, p_dados jsonb
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_link text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;
  v_link=nullif(trim(coalesce(p_dados->>'link_maps','')),'');
  if length(trim(coalesce(p_dados->>'cidade','')))<2
    or length(trim(coalesce(p_dados->>'nome_espaco','')))<2
    or length(trim(coalesce(p_dados->>'endereco','')))<5
    or (v_link is not null and v_link !~* '^https?://') then return false; end if;
  update public.configuracao_evento set
    data_evento=(p_dados->>'data')::date,
    hora_evento=(p_dados->>'hora')::time,
    cidade=trim(p_dados->>'cidade'),
    local_liberado=coalesce((p_dados->>'local_liberado')::boolean,false),
    nome_espaco=trim(p_dados->>'nome_espaco'),
    endereco=trim(p_dados->>'endereco'),
    link_maps=v_link,
    atualizado_em=now()
  where id=true;
  return found;
exception when invalid_text_representation or datetime_field_overflow then
  return false;
end $$;

create or replace function public.administrar_status_convite(
  p_token_hash text, p_convidado_id uuid, p_status text
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid; v_expirado boolean; v_anterior text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
  ) then return false; end if;
  select c.id,(not c.sem_expiracao and c.expira_em<=now()),cf.status
  into v_convite_id,v_expirado,v_anterior
  from public.convidados g join public.convites c on c.id=g.convite_id
  left join public.confirmacoes cf on cf.convidado_id=g.id
  where g.id=p_convidado_id;
  if v_convite_id is null then return false; end if;
  if p_status='aguardando' then
    delete from public.confirmacoes where convidado_id=p_convidado_id;
    if v_expirado then
      update public.convites set expira_em=public.prazo_padrao_convite(),
        sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
    end if;
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'aguardando','dashboard');
  elsif p_status='confirmado' then
    insert into public.confirmacoes(convite_id,convidado_id,status,atualizado_em)
    values(v_convite_id,p_convidado_id,'sim',now())
    on conflict(convite_id,convidado_id) do update set status='sim',atualizado_em=now();
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'sim','dashboard');
  elsif p_status='expirado' then
    delete from public.confirmacoes where convidado_id=p_convidado_id;
    update public.convites set expira_em=now()-interval '1 second',
      sem_expiracao=false,atualizado_em=now() where id=v_convite_id;
    perform public.registrar_notificacao_status(v_convite_id,p_convidado_id,v_anterior,'expirado','dashboard');
  else return false; end if;
  return true;
end $$;

create or replace function public.salvar_confirmacao(
  p_codigo text, p_respostas jsonb, p_mensagem text default null
) returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_convite_id uuid; v_item jsonb; v_id uuid; v_status text; v_anterior text;
  v_idade smallint; v_limite smallint; v_prazo_vencido boolean; v_tinha_confirmado boolean;
begin
  select c.id,(not c.sem_expiracao and c.expira_em<=now()),
    exists(select 1 from public.confirmacoes cf where cf.convite_id=c.id and cf.status='sim')
  into v_convite_id,v_prazo_vencido,v_tinha_confirmado
  from public.convites c where c.id=coalesce(
    (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
    (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
  ) and c.ativo;
  select idade_limite_crianca into v_limite from public.configuracao_evento where id=true;
  if v_convite_id is null or jsonb_typeof(p_respostas)<>'array'
    or (v_prazo_vencido and not v_tinha_confirmado) then return false; end if;
  for v_item in select * from jsonb_array_elements(p_respostas) loop
    v_id=(v_item->>'convidado_id')::uuid; v_status=v_item->>'status';
    if v_status not in ('sim','nao') or not exists(
      select 1 from public.convidados where id=v_id and convite_id=v_convite_id
    ) then return false; end if;
    select status into v_anterior from public.confirmacoes where convidado_id=v_id;
    if v_status='sim' and exists(select 1 from public.convidados where id=v_id and crianca) then
      v_idade=(v_item->>'idade')::smallint;
      if v_idade is null or v_idade not between 0 and 17 then return false; end if;
      update public.convidados set idade_confirmada=v_idade,crianca=(v_idade<=v_limite) where id=v_id;
    end if;
    insert into public.confirmacoes(convite_id,convidado_id,status,mensagem,atualizado_em)
    values(v_convite_id,v_id,v_status,nullif(trim(p_mensagem),''),now())
    on conflict(convite_id,convidado_id) do update set
      status=excluded.status,mensagem=excluded.mensagem,atualizado_em=now();
    perform public.registrar_notificacao_status(v_convite_id,v_id,v_anterior,v_status,'convite');
  end loop;
  if v_prazo_vencido and not exists(
    select 1 from public.confirmacoes where convite_id=v_convite_id and status='sim'
  ) then
    delete from public.confirmacoes where convite_id=v_convite_id;
  end if;
  return true;
exception when invalid_text_representation then return false;
end $$;

-- Reaplica as funções de leitura com as novas regras sem duplicar a estrutura.
create or replace function public.evento_publico()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'data',to_char(data_evento,'YYYY-MM-DD'),
    'hora',to_char(hora_evento,'HH24:MI'),
    'cidade',cidade,
    'local_liberado',local_liberado,
    'nome_espaco',nome_espaco,
    'endereco',endereco,
    'link_maps',link_maps
  ) from public.configuracao_evento where id=true
$$;

-- Acrescenta notificações às mensagens retornadas pelo painel.
-- As funções completas de dashboard e busca da migração 018 são substituídas
-- abaixo por wrappers que enriquecem o JSON produzido pelas versões internas.
alter function public.dashboard_noivos(text) rename to dashboard_noivos_018;
alter function public.buscar_convite(text) rename to buscar_convite_018;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'evento',public.evento_publico(),
      'convidados',coalesce((
        select jsonb_agg(
          item || jsonb_build_object(
            'status',case
              when coalesce((item->>'expirado')::boolean,false)
                and coalesce(item->>'resposta','')<>'sim' then 'expirado'
              else item->>'status'
            end,
            'expirado',coalesce((item->>'expirado')::boolean,false)
              and coalesce(item->>'resposta','')<>'sim'
          )
        )
        from jsonb_array_elements(coalesce(base->'convidados','[]'::jsonb)) item
      ),'[]'::jsonb),
      'mensagens',coalesce(base->'mensagens','[]'::jsonb) || coalesce((
        select jsonb_agg(jsonb_build_object(
          'grupo',c.nome_familia,'codigo',c.codigo,'mensagem',n.mensagem,'atualizado_em',n.criado_em
        ) order by n.criado_em desc)
        from public.notificacoes_organizacao n join public.convites c on c.id=n.convite_id
      ),'[]'::jsonb)
    ) end
  from (select public.dashboard_noivos_018(p_token_hash) base) x
$$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb language sql security definer set search_path=public as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'evento',public.evento_publico(),
      'prazo_vencido',coalesce((base->>'expirado')::boolean,false),
      'expirado',coalesce((base->>'expirado')::boolean,false)
        and not exists(
          select 1 from public.confirmacoes cf
          join public.convidados g on g.id=cf.convidado_id
          where g.convite_id=(
            select c.id from public.convites c where c.id=coalesce(
              (select convite_id from public.convidados where codigo_individual=upper(trim(p_codigo)) limit 1),
              (select id from public.convites where codigo=upper(trim(p_codigo)) limit 1)
            )
          ) and cf.status='sim'
        )
    ) end
  from (select public.buscar_convite_018(p_codigo) base) x
$$;

revoke all on function public.administrar_configuracao_evento(text,jsonb) from public;
grant execute on function public.administrar_configuracao_evento(text,jsonb),
  public.dashboard_noivos(text),public.buscar_convite(text),
  public.salvar_confirmacao(text,jsonb,text) to anon,authenticated;

notify pgrst, 'reload schema';
