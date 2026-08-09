begin;

alter table public.reservas_presentes
  add column if not exists tentativa_pagamento_ate timestamptz,
  add column if not exists conciliacao_pagamento_ate timestamptz,
  add column if not exists checkout_url text,
  add column if not exists tipo_pagamento text,
  add column if not exists boleto_vencimento timestamptz;

create index if not exists reservas_pagamento_expiracao_idx
  on public.reservas_presentes (conciliacao_pagamento_ate)
  where meio='mercado_pago' and status='pendente';

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
  v_convite_id uuid;
  v_item jsonb;
  v_presente_id uuid;
  v_quantidade integer;
  v_usada integer;
  v_total integer;
begin
  perform public.expirar_reservas_pagamento();

  select c.id into v_convite_id
    from public.convites c
   where c.ativo=true and (
     c.codigo=upper(trim(p_codigo)) or exists (
       select 1 from public.convidados g
        where g.convite_id=c.id
          and g.codigo_individual=upper(trim(p_codigo))
     )
   )
   limit 1;

  if v_convite_id is null
     or jsonb_typeof(p_itens)<>'array'
     or jsonb_array_length(p_itens)<1
     or jsonb_array_length(p_itens)>30
     or nullif(trim(p_preferencia_id),'') is null
     or nullif(trim(p_external_reference),'') is null
     or nullif(trim(p_checkout_url),'') is null
     or p_tentativa_pagamento_ate<=now()
     or p_conciliacao_pagamento_ate<=p_tentativa_pagamento_ate
  then
    return false;
  end if;

  for v_item in
    select value
      from jsonb_array_elements(p_itens)
     order by value->>'presente_id'
  loop
    v_presente_id := (v_item->>'presente_id')::uuid;
    v_quantidade := (v_item->>'quantidade')::integer;

    select quantidade_total into v_total
      from public.presentes
     where id=v_presente_id and ativo=true
     for update;

    if not found or v_quantidade<1 or v_quantidade>20 then
      raise exception 'reserva_indisponivel';
    end if;

    select coalesce(sum(quantidade),0)::integer into v_usada
      from public.reservas_presentes
     where presente_id=v_presente_id
       and status in ('pendente','confirmado');

    if v_usada+v_quantidade>v_total then
      raise exception 'reserva_indisponivel';
    end if;

    insert into public.reservas_presentes(
      convite_id,presente_id,quantidade,status,meio,preferencia_id,
      external_reference,pagamento_status,tentativa_pagamento_ate,
      conciliacao_pagamento_ate,checkout_url,doador_chave,cpf_cifrado,
      cpf_consentimento_em,cpf_politica_versao,mensagem
    ) values (
      v_convite_id,v_presente_id,v_quantidade,'pendente','mercado_pago',
      p_preferencia_id,p_external_reference,'pending',
      p_tentativa_pagamento_ate,p_conciliacao_pagamento_ate,p_checkout_url,
      p_doador_chave,p_cpf_cifrado,p_cpf_consentimento_em,
      p_cpf_politica_versao,nullif(left(trim(p_mensagem),1000),'')
    );
  end loop;

  return true;
exception
  when raise_exception or unique_violation or invalid_text_representation
    or not_null_violation or check_violation then
    return false;
end;
$$;

create or replace function public.expirar_reservas_pagamento()
returns integer language plpgsql security definer set search_path=public as $$
declare v_total integer;
begin
  update public.reservas_presentes
     set status='cancelado',
         pagamento_status='cancelled_by_timeout',
         atualizado_em=now()
   where meio='mercado_pago'
     and status='pendente'
     and coalesce(tipo_pagamento,'') not in ('ticket','bolbradesco','pec')
     and conciliacao_pagamento_ate is not null
     and conciliacao_pagamento_ate <= now();
  get diagnostics v_total = row_count;
  return v_total;
end $$;

create or replace function public.listar_presentes()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'nome',p.nome,'descricao',p.descricao,'imagens',coalesce(p.imagens,'{}'),
    'categoria_id',p.categoria_id,'categoria',c.nome,'preco_centavos',p.preco_centavos,
    'quantidade_total',p.quantidade_total,'quantidade_assinada',coalesce(r.assinada,0),
    'quantidade_restante',greatest(p.quantidade_total-coalesce(r.assinada,0),0)
  ) order by c.ordem nulls last,p.ordem,p.nome),'[]'::jsonb)
  from public.presentes p
  left join public.categorias_presentes c on c.id=p.categoria_id and c.ativo
  left join (
    select presente_id,sum(quantidade)::integer assinada
      from public.reservas_presentes
     where status in ('pendente','confirmado')
     group by presente_id
  ) r on r.presente_id=p.id
  where p.ativo;
$$;

create or replace function public.listar_historico_presentes(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_resultado jsonb;
begin
  perform public.expirar_reservas_pagamento();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'presente_id',r.presente_id,'presente',p.nome,'quantidade',r.quantidade,
    'meio',r.meio,'status',r.status,'pagamento_status',r.pagamento_status,
    'editavel',(r.meio='fisico' and r.status='confirmado'),
    'pode_tentar_pagamento',(r.meio='mercado_pago' and r.status='pendente' and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec') and r.tentativa_pagamento_ate>now()),
    'checkout_url',(case when r.meio='mercado_pago' and r.status='pendente' and coalesce(r.tipo_pagamento,'') not in ('ticket','bolbradesco','pec') and r.tentativa_pagamento_ate>now() then r.checkout_url else null end),
    'tentativa_pagamento_ate',r.tentativa_pagamento_ate,
    'conciliacao_pagamento_ate',r.conciliacao_pagamento_ate,
    'tipo_pagamento',r.tipo_pagamento,
    'boleto_vencimento',r.boleto_vencimento,
    'criado_em',r.criado_em,'aprovado_em',r.aprovado_em
  ) order by r.criado_em desc),'[]'::jsonb) into v_resultado
  from public.reservas_presentes r
  join public.presentes p on p.id=r.presente_id
  join public.convites c on c.id=r.convite_id
  where c.ativo=true and (
    c.codigo=upper(trim(p_codigo)) or exists(
      select 1 from public.convidados g where g.convite_id=c.id and g.codigo_individual=upper(trim(p_codigo))
    )
  );
  return v_resultado;
end $$;

revoke all on function public.expirar_reservas_pagamento() from public;
grant execute on function public.expirar_reservas_pagamento() to service_role;
revoke all on function public.reservar_presentes_pagamento(text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text) from public;
grant execute on function public.reservar_presentes_pagamento(text,jsonb,text,text,text,timestamptz,timestamptz,text,text,timestamptz,text,text) to service_role;
grant execute on function public.listar_presentes() to anon,authenticated;
revoke all on function public.listar_historico_presentes(text) from public;
grant execute on function public.listar_historico_presentes(text) to anon,authenticated;

notify pgrst,'reload schema';
commit;
