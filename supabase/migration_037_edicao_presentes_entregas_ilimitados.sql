begin;

-- Quantidade nula representa um presente que pode ser assinado sem limite.
alter table public.presentes
  alter column quantidade_total drop not null;

alter table public.presentes
  drop constraint if exists presentes_quantidade_total_check;

alter table public.presentes
  add constraint presentes_quantidade_total_check
  check (quantidade_total is null or quantidade_total between 1 and 10000);

-- Guarda o codigo efetivamente usado pelo presenteador e o recebimento fisico.
alter table public.reservas_presentes
  add column if not exists codigo_doador text,
  add column if not exists entregue_em timestamptz,
  add column if not exists entregue_por uuid references public.organizacao(id) on delete set null;

update public.reservas_presentes r
set codigo_doador=c.codigo
from public.convites c
where c.id=r.convite_id and r.codigo_doador is null;

alter table public.reservas_presentes
  drop constraint if exists reservas_presentes_codigo_doador_check;

alter table public.reservas_presentes
  add constraint reservas_presentes_codigo_doador_check
  check (codigo_doador is null or codigo_doador ~ '^[A-Z0-9]{6}$');

create index if not exists reservas_presentes_entrega_idx
  on public.reservas_presentes (entregue_em, criado_em desc)
  where meio='fisico' and status='confirmado';

create or replace function public.importar_presentes_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_item jsonb; v_nome text; v_categoria text; v_categoria_id uuid;
  v_descricao text; v_imagens text[]; v_valor numeric; v_quantidade integer;
  v_ordem integer; v_total integer:=0; v_permitir_duplicado boolean;
  v_nome_normalizado text;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas)<>'array'
    or jsonb_array_length(p_linhas) not between 1 and 1000
  then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome:=trim(coalesce(v_item->>'nome',''));
    v_categoria:=trim(coalesce(v_item->>'categoria',''));
    v_descricao:=nullif(trim(coalesce(v_item->>'descricao','')),'');
    v_valor:=(v_item->>'valor')::numeric;
    v_quantidade:=nullif(
      trim(coalesce(v_item->>'quantidade','')),
      ''
    )::integer;
    v_permitir_duplicado:=coalesce(
      (v_item->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value),'{}') into v_imagens
    from jsonb_array_elements_text(coalesce(v_item->'links_fotos','[]'::jsonb));

    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2
      or v_valor<0 or v_valor>1000000
      or (v_quantidade is not null and v_quantidade not between 1 and 10000)
      or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
    then return -2; end if;

    v_nome_normalizado:=lower(
      regexp_replace(trim(v_nome),'[[:space:]]+',' ','g')
    );
    if not v_permitir_duplicado and exists(
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome),'[[:space:]]+',' ','g'))
          =v_nome_normalizado
    ) then continue; end if;

    select id into v_categoria_id
    from public.categorias_presentes
    where lower(trim(nome))=lower(v_categoria)
    order by ativo desc,ordem
    limit 1;
    if v_categoria_id is null then
      select coalesce(max(ordem),0)+1 into v_ordem
      from public.categorias_presentes;
      insert into public.categorias_presentes(nome,ordem)
      values(v_categoria,v_ordem)
      returning id into v_categoria_id;
    else
      update public.categorias_presentes set ativo=true where id=v_categoria_id;
    end if;

    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(
      nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
    ) values(
      v_nome,v_descricao,round(v_valor*100)::integer,v_quantidade,
      v_ordem,v_categoria_id,v_imagens
    );
    v_total:=v_total+1;
  end loop;
  return v_total;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return -2;
end $$;

create or replace function public.administrar_presente_dashboard(
  p_token_hash text,
  p_acao text,
  p_dados jsonb
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid; v_nome text; v_descricao text; v_categoria_id uuid;
  v_preco_centavos integer; v_quantidade_total integer; v_imagens text[];
  v_ordem integer; v_permitir_duplicado boolean; v_nome_normalizado text;
  v_quantidade_usada integer;
begin
  if not exists(
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;

  if p_acao in ('criar','editar') then
    if p_acao='editar' then
      v_id:=nullif(p_dados->>'id','')::uuid;
      if not exists(select 1 from public.presentes where id=v_id and ativo)
      then return false; end if;
    end if;

    v_nome:=trim(coalesce(p_dados->>'nome',''));
    v_descricao:=nullif(trim(coalesce(p_dados->>'descricao','')),'');
    v_categoria_id:=nullif(p_dados->>'categoria_id','')::uuid;
    v_preco_centavos:=(p_dados->>'preco_centavos')::integer;
    v_quantidade_total:=nullif(
      trim(coalesce(p_dados->>'quantidade_total','')),
      ''
    )::integer;
    v_permitir_duplicado:=coalesce(
      (p_dados->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value),'{}') into v_imagens
    from jsonb_array_elements_text(coalesce(p_dados->'imagens','[]'::jsonb));

    if length(v_nome) not between 2 and 150
      or coalesce(length(v_descricao),0)>1000
      or v_preco_centavos not between 0 and 100000000
      or (
        v_quantidade_total is not null
        and v_quantidade_total not between 1 and 10000
      )
      or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
      or (
        v_categoria_id is not null
        and not exists(
          select 1 from public.categorias_presentes
          where id=v_categoria_id and ativo
        )
      )
    then return false; end if;

    v_nome_normalizado:=lower(
      regexp_replace(trim(v_nome),'[[:space:]]+',' ','g')
    );
    if not v_permitir_duplicado and exists(
      select 1 from public.presentes p
      where p.ativo
        and (v_id is null or p.id<>v_id)
        and lower(regexp_replace(trim(p.nome),'[[:space:]]+',' ','g'))
          =v_nome_normalizado
    ) then return false; end if;

    if p_acao='criar' then
      select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
      insert into public.presentes(
        nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
      ) values(
        v_nome,v_descricao,v_preco_centavos,v_quantidade_total,v_ordem,
        v_categoria_id,v_imagens
      );
    else
      select coalesce(sum(quantidade),0)::integer into v_quantidade_usada
      from public.reservas_presentes
      where presente_id=v_id and status in ('pendente','confirmado');
      if v_quantidade_total is not null
        and v_quantidade_total<v_quantidade_usada
      then return false; end if;
      update public.presentes set
        nome=v_nome,
        descricao=v_descricao,
        preco_centavos=v_preco_centavos,
        quantidade_total=v_quantidade_total,
        categoria_id=v_categoria_id,
        imagens=v_imagens
      where id=v_id and ativo;
      if not found then return false; end if;
    end if;
    return true;
  elsif p_acao='excluir' then
    v_id:=nullif(p_dados->>'id','')::uuid;
    update public.presentes set ativo=false where id=v_id and ativo;
    return found;
  end if;
  return false;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation or unique_violation
  then return false;
end $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,
    'nome',p.nome,
    'descricao',p.descricao,
    'imagens',coalesce(p.imagens,'{}'),
    'categoria_id',p.categoria_id,
    'categoria',c.nome,
    'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,
    'quantidade_ilimitada',(p.quantidade_total is null),
    'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',case
      when p.quantidade_total is null then null
      else greatest(p.quantidade_total-coalesce(r.assinada,0),0)
    end
  ) order by c.ordem nulls last,p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join public.categorias_presentes c on c.id=p.categoria_id and c.ativo
  left join(
    select presente_id,sum(quantidade)::integer assinada
    from public.reservas_presentes
    where status in ('pendente','confirmado')
    group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo;
$$;

create or replace function public.registrar_presentes_fisicos(
  p_codigo text,
  p_itens jsonb,
  p_mensagem text default null
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_convite_id uuid; v_item jsonb; v_presente_id uuid;
  v_quantidade integer; v_usada integer; v_total integer;
  v_codigo text:=upper(trim(p_codigo));
begin
  select c.id into v_convite_id
  from public.convites c
  where c.ativo=true and (
    c.codigo=v_codigo or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id and g.codigo_individual=v_codigo
    )
  ) limit 1;
  if v_convite_id is null or jsonb_typeof(p_itens)<>'array'
    or jsonb_array_length(p_itens) not between 1 and 30
  then return false; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_presente_id:=(v_item->>'presente_id')::uuid;
    v_quantidade:=(v_item->>'quantidade')::integer;
    select quantidade_total into v_total
    from public.presentes
    where id=v_presente_id and ativo=true
    for update;
    if not found or v_quantidade not between 1 and 20 then return false; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada
    from public.reservas_presentes
    where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_total is not null and v_usada+v_quantidade>v_total
    then return false; end if;
    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,mensagem,codigo_doador
    ) values(
      v_convite_id,v_presente_id,v_quantidade,'confirmado','fisico',
      nullif(left(trim(p_mensagem),1000),''),v_codigo
    );
  end loop;
  return true;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return false;
end $$;

create or replace function public.alterar_presente_fisico(
  p_codigo text,
  p_reserva_id uuid,
  p_quantidade integer,
  p_cancelar boolean default false
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_reserva public.reservas_presentes%rowtype;
  v_usada integer; v_total integer;
begin
  select r.* into v_reserva
  from public.reservas_presentes r
  join public.convites c on c.id=r.convite_id
  where r.id=p_reserva_id and r.meio='fisico' and r.status='confirmado'
    and r.entregue_em is null and c.ativo=true and (
      c.codigo=upper(trim(p_codigo)) or exists(
        select 1 from public.convidados g
        where g.convite_id=c.id
          and g.codigo_individual=upper(trim(p_codigo))
      )
    )
  for update of r;
  if not found then return false; end if;
  if p_cancelar then
    update public.reservas_presentes
    set status='cancelado',atualizado_em=now()
    where id=p_reserva_id;
    return true;
  end if;
  if p_quantidade not between 1 and 20 then return false; end if;
  select quantidade_total into v_total
  from public.presentes
  where id=v_reserva.presente_id
  for update;
  select coalesce(sum(quantidade),0)::integer into v_usada
  from public.reservas_presentes
  where presente_id=v_reserva.presente_id
    and status in ('pendente','confirmado')
    and id<>p_reserva_id;
  if v_total is not null and v_usada+p_quantidade>v_total
  then return false; end if;
  update public.reservas_presentes
  set quantidade=p_quantidade,atualizado_em=now()
  where id=p_reserva_id;
  return true;
end $$;

create or replace function public.reservar_presentes_pagamento(
  p_codigo text,
  p_itens jsonb,
  p_preferencia_id text,
  p_external_reference text,
  p_checkout_url text,
  p_tentativa_pagamento_ate timestamptz,
  p_conciliacao_pagamento_ate timestamptz,
  p_doador_chave text,
  p_cpf_cifrado text,
  p_cpf_consentimento_em timestamptz,
  p_cpf_politica_versao text,
  p_mensagem text
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_convite_id uuid; v_item jsonb; v_presente_id uuid;
  v_quantidade integer; v_usada integer; v_total integer;
  v_codigo text:=upper(trim(p_codigo));
begin
  perform public.expirar_reservas_pagamento();
  select c.id into v_convite_id
  from public.convites c
  where c.ativo=true and (
    c.codigo=v_codigo or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id and g.codigo_individual=v_codigo
    )
  ) limit 1;
  if v_convite_id is null
    or jsonb_typeof(p_itens)<>'array'
    or jsonb_array_length(p_itens) not between 1 and 30
    or nullif(trim(p_preferencia_id),'') is null
    or nullif(trim(p_external_reference),'') is null
    or nullif(trim(p_checkout_url),'') is null
    or p_tentativa_pagamento_ate<=now()
    or p_conciliacao_pagamento_ate<=p_tentativa_pagamento_ate
  then return false; end if;

  for v_item in
    select value from jsonb_array_elements(p_itens)
    order by value->>'presente_id'
  loop
    v_presente_id:=(v_item->>'presente_id')::uuid;
    v_quantidade:=(v_item->>'quantidade')::integer;
    select quantidade_total into v_total
    from public.presentes
    where id=v_presente_id and ativo=true
    for update;
    if not found or v_quantidade not between 1 and 20
    then raise exception 'reserva_indisponivel'; end if;
    select coalesce(sum(quantidade),0)::integer into v_usada
    from public.reservas_presentes
    where presente_id=v_presente_id and status in ('pendente','confirmado');
    if v_total is not null and v_usada+v_quantidade>v_total
    then raise exception 'reserva_indisponivel'; end if;
    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,preferencia_id,
      external_reference,pagamento_status,tentativa_pagamento_ate,
      conciliacao_pagamento_ate,checkout_url,doador_chave,cpf_cifrado,
      cpf_consentimento_em,cpf_politica_versao,mensagem,codigo_doador
    ) values(
      v_convite_id,v_presente_id,v_quantidade,'pendente','mercado_pago',
      p_preferencia_id,p_external_reference,'pending',p_tentativa_pagamento_ate,
      p_conciliacao_pagamento_ate,p_checkout_url,p_doador_chave,p_cpf_cifrado,
      p_cpf_consentimento_em,p_cpf_politica_versao,
      nullif(left(trim(p_mensagem),1000),''),v_codigo
    );
  end loop;
  return true;
exception
  when raise_exception or unique_violation or invalid_text_representation
    or not_null_violation or check_violation
  then return false;
end $$;

create or replace function public.listar_historico_presentes(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_resultado jsonb;
begin
  perform public.expirar_reservas_pagamento();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,
    'presente_id',r.presente_id,
    'presente',p.nome,
    'quantidade',r.quantidade,
    'meio',r.meio,
    'status',r.status,
    'status_entrega',case
      when r.meio='fisico' and r.entregue_em is not null then 'Entregue'
      when r.meio='fisico' and r.status='confirmado' then 'Assinado'
      else null
    end,
    'entregue_em',r.entregue_em,
    'pagamento_status',r.pagamento_status,
    'editavel',(
      r.meio='fisico' and r.status='confirmado' and r.entregue_em is null
    ),
    'pode_tentar_pagamento',(
      r.meio='mercado_pago' and r.status='pendente'
      and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
      and r.tentativa_pagamento_ate>now()
    ),
    'checkout_url',case
      when r.meio='mercado_pago' and r.status='pendente'
        and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
        and r.tentativa_pagamento_ate>now()
      then r.checkout_url else null
    end,
    'tentativa_pagamento_ate',r.tentativa_pagamento_ate,
    'conciliacao_pagamento_ate',r.conciliacao_pagamento_ate,
    'tipo_pagamento',r.tipo_pagamento,
    'boleto_vencimento',r.boleto_vencimento,
    'criado_em',r.criado_em,
    'aprovado_em',r.aprovado_em
  ) order by r.criado_em desc),'[]'::jsonb) into v_resultado
  from public.reservas_presentes r
  join public.presentes p on p.id=r.presente_id
  join public.convites c on c.id=r.convite_id
  where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(
      select 1 from public.convidados g
      where g.convite_id=c.id
        and g.codigo_individual=upper(trim(p_codigo))
    )
  );
  return v_resultado;
end $$;

create or replace function public.administrar_entrega_presente(
  p_token_hash text,
  p_reserva_id uuid,
  p_entregue boolean
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_organizacao_id uuid;
begin
  select o.id into v_organizacao_id
  from public.sessoes_organizacao s
  join public.organizacao o on o.id=s.organizacao_id
  where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
    and (o.administrador or o.funcao in ('noivo','noiva'));
  if not found then return false; end if;
  update public.reservas_presentes set
    entregue_em=case when p_entregue then now() else null end,
    entregue_por=case when p_entregue then v_organizacao_id else null end,
    atualizado_em=now()
  where id=p_reserva_id and meio='fisico' and status='confirmado';
  return found;
end $$;

do $$
begin
  if to_regprocedure('public.dashboard_noivos_036(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_036;
  end if;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb
language sql
security definer
set search_path=public
as $$
  select case when base is null then null else
    base || jsonb_build_object(
      'reservas',case when base->>'perfil'='assessoria' then '[]'::jsonb
      else coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',r.id,
          'convidado',c.nome_familia,
          'codigo',coalesce(r.codigo_doador,c.codigo),
          'presente',p.nome,
          'quantidade',r.quantidade,
          'meio',r.meio,
          'status_entrega',case
            when r.meio='fisico' and r.entregue_em is not null then 'Entregue'
            when r.meio='fisico' then 'Assinado'
            else 'Pago'
          end,
          'entregue_em',r.entregue_em,
          'entregue_por_nome',o.nome,
          'criado_em',r.criado_em
        ) order by r.criado_em desc)
        from public.reservas_presentes r
        join public.convites c on c.id=r.convite_id
        join public.presentes p on p.id=r.presente_id
        left join public.organizacao o on o.id=r.entregue_por
        where r.status='confirmado'
      ),'[]'::jsonb) end
    ) end
  from(select public.dashboard_noivos_036(p_token_hash) base)x;
$$;

revoke all on function public.importar_presentes_automatico(text,jsonb) from public;
revoke all on function public.administrar_presente_dashboard(text,text,jsonb) from public;
revoke all on function public.registrar_presentes_fisicos(text,jsonb,text) from public;
revoke all on function public.alterar_presente_fisico(text,uuid,integer,boolean) from public;
revoke all on function public.reservar_presentes_pagamento(
  text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text
) from public;
revoke all on function public.listar_historico_presentes(text) from public;
revoke all on function public.administrar_entrega_presente(text,uuid,boolean) from public;
revoke all on function public.dashboard_noivos_036(text) from public;
revoke all on function public.dashboard_noivos_036(text) from anon,authenticated;
revoke all on function public.dashboard_noivos(text) from public;

grant execute on function public.importar_presentes_automatico(text,jsonb),
  public.administrar_presente_dashboard(text,text,jsonb),
  public.listar_presentes(),
  public.registrar_presentes_fisicos(text,jsonb,text),
  public.alterar_presente_fisico(text,uuid,integer,boolean),
  public.listar_historico_presentes(text),
  public.administrar_entrega_presente(text,uuid,boolean),
  public.dashboard_noivos(text)
to anon,authenticated;

grant execute on function public.reservar_presentes_pagamento(
  text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text
) to service_role;

notify pgrst,'reload schema';
commit;
