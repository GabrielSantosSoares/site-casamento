begin;

-- Remove informações que nunca devem ser copiadas para o histórico.
create or replace function public.sanitizar_dados_auditoria(valor jsonb)
returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare
  resultado jsonb := '{}'::jsonb;
  item record;
begin
  if valor is null then return null; end if;
  if jsonb_typeof(valor) <> 'object' then return valor; end if;

  for item in select key, value from jsonb_each(valor) loop
    if item.key ~* '(cpf|token|secret|segredo|senha|password|hash|authorization|access[_-]?key|public[_-]?key|client[_-]?id|client[_-]?secret|credencial|cifrado)' then
      resultado := resultado || jsonb_build_object(item.key, '[PROTEGIDO]');
    else
      resultado := resultado || jsonb_build_object(item.key, item.value);
    end if;
  end loop;
  return resultado;
end $$;

create or replace function public.registrar_auditoria_tabela()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_antes jsonb;
  v_depois jsonb;
  v_campos text[] := array[]::text[];
  v_chave text;
  v_id text;
begin
  v_antes := case when tg_op in ('UPDATE','DELETE') then public.sanitizar_dados_auditoria(to_jsonb(old)) else null end;
  v_depois := case when tg_op in ('INSERT','UPDATE') then public.sanitizar_dados_auditoria(to_jsonb(new)) else null end;
  v_id := coalesce(v_depois->>'id', v_antes->>'id', '');

  if tg_op = 'UPDATE' then
    for v_chave in
      select key from (
        select jsonb_object_keys(coalesce(v_antes, '{}'::jsonb)) as key
        union
        select jsonb_object_keys(coalesce(v_depois, '{}'::jsonb)) as key
      ) chaves
      where coalesce(v_antes->key, 'null'::jsonb) is distinct from coalesce(v_depois->key, 'null'::jsonb)
      order by key
    loop
      v_campos := array_append(v_campos, v_chave);
    end loop;
  elsif tg_op = 'INSERT' then
    v_campos := array['registro_criado'];
  else
    v_campos := array['registro_excluido'];
  end if;

  insert into public.auditoria_administrativa(ator,perfil,acao,entidade,detalhes)
  values(
    'Aplicação',
    'sistema',
    lower(tg_op),
    tg_table_name,
    jsonb_build_object(
      'id', v_id,
      'campos_alterados', to_jsonb(v_campos),
      'antes', v_antes,
      'depois', v_depois
    )
  );
  return coalesce(new,old);
end $$;

comment on function public.sanitizar_dados_auditoria(jsonb) is
  'Oculta CPFs, senhas, tokens e credenciais antes de registrar antes/depois na auditoria.';

notify pgrst, 'reload schema';
commit;
