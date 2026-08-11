-- Compatibilidade da lista de pagamentos e persistência do código usado para
-- presentear. As demais correções desta versão são aplicadas no aplicativo.
begin;

alter table public.reservas_presentes
  add column if not exists codigo_doador text;

update public.reservas_presentes r
set codigo_doador = c.codigo
from public.convites c
where c.id = r.convite_id
  and r.codigo_doador is null;

alter table public.reservas_presentes
  drop constraint if exists reservas_presentes_codigo_doador_check;

alter table public.reservas_presentes
  add constraint reservas_presentes_codigo_doador_check
  check (codigo_doador is null or codigo_doador ~ '^[A-Z0-9]{6}$');

create index if not exists reservas_presentes_codigo_doador_idx
  on public.reservas_presentes (codigo_doador, criado_em desc);

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
set search_path = public
as $$
declare
  v_convite_id uuid;
  v_item jsonb;
  v_presente_id uuid;
  v_quantidade integer;
  v_usada integer;
  v_total integer;
  v_codigo text := upper(trim(p_codigo));
begin
  perform public.expirar_reservas_pagamento();

  select c.id into v_convite_id
  from public.convites c
  where c.ativo = true and (
    c.codigo = v_codigo or exists (
      select 1
      from public.convidados g
      where g.convite_id = c.id
        and g.codigo_individual = v_codigo
    )
  )
  limit 1;

  if v_convite_id is null
    or jsonb_typeof(p_itens) <> 'array'
    or jsonb_array_length(p_itens) not between 1 and 30
    or nullif(trim(p_preferencia_id), '') is null
    or nullif(trim(p_external_reference), '') is null
    or nullif(trim(p_checkout_url), '') is null
    or p_tentativa_pagamento_ate <= now()
    or p_conciliacao_pagamento_ate <= p_tentativa_pagamento_ate
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
    where id = v_presente_id and ativo = true
    for update;

    if not found or v_quantidade not between 1 and 20 then
      raise exception 'reserva_indisponivel';
    end if;

    select coalesce(sum(quantidade), 0)::integer into v_usada
    from public.reservas_presentes
    where presente_id = v_presente_id
      and status in ('pendente', 'confirmado');

    if v_total is not null and v_usada + v_quantidade > v_total then
      raise exception 'reserva_indisponivel';
    end if;

    insert into public.reservas_presentes (
      convite_id, presente_id, quantidade, status, meio, preferencia_id,
      external_reference, pagamento_status, tentativa_pagamento_ate,
      conciliacao_pagamento_ate, checkout_url, doador_chave, cpf_cifrado,
      cpf_consentimento_em, cpf_politica_versao, mensagem, codigo_doador
    ) values (
      v_convite_id, v_presente_id, v_quantidade, 'pendente', 'mercado_pago',
      p_preferencia_id, p_external_reference, 'pending',
      p_tentativa_pagamento_ate, p_conciliacao_pagamento_ate, p_checkout_url,
      p_doador_chave, p_cpf_cifrado, p_cpf_consentimento_em,
      p_cpf_politica_versao, nullif(left(trim(p_mensagem), 1000), ''),
      v_codigo
    );
  end loop;

  return true;
exception
  when raise_exception or unique_violation or invalid_text_representation
    or not_null_violation or check_violation
  then return false;
end $$;

revoke all on function public.reservar_presentes_pagamento(
  text, jsonb, text, text, text, timestamptz, timestamptz, text, text,
  timestamptz, text, text
) from public;

grant execute on function public.reservar_presentes_pagamento(
  text, jsonb, text, text, text, timestamptz, timestamptz, text, text,
  timestamptz, text, text
) to service_role;

notify pgrst, 'reload schema';
commit;
