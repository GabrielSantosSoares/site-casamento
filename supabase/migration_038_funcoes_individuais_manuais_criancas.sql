-- Privacidade das funções e manuais personalizados por convidado.
begin;

do $$
begin
  if to_regprocedure('public.buscar_convite_037(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_037;
  end if;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_resultado jsonb;
  v_convidados jsonb;
  v_responsaveis jsonb;
  v_pessoa jsonb;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_pode_gerenciar_criancas boolean := false;
begin
  select public.buscar_convite_037(p_codigo) into v_resultado;
  if v_resultado is null then return null; end if;

  if v_resultado->>'perfil_acesso' in ('noivos', 'assessoria', 'admin') then
    return v_resultado;
  end if;

  select item
    into v_pessoa
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb)) as x(item)
  where upper(trim(coalesce(item->>'codigo_individual', ''))) = v_codigo
  limit 1;

  v_pode_gerenciar_criancas :=
    coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
    and not coalesce((v_pessoa->>'crianca')::boolean, false);

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id'
          or (
            v_pode_gerenciar_criancas
            and coalesce((item->>'crianca')::boolean, false)
            and nullif(trim(coalesce(item->>'funcao', '')), '') is not null
          )
        then item || jsonb_build_object(
          'codigo_individual',
          case
            when coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
              or item->>'id' = v_pessoa->>'id'
            then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
        else item || jsonb_build_object(
          'funcao', null,
          'codigo_individual',
          case
            when coalesce((v_pessoa->>'pode_gerenciar')::boolean, false)
            then item->>'codigo_individual'
            else 'PROTEGIDO'
          end
        )
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_convidados
  from jsonb_array_elements(coalesce(v_resultado->'convidados', '[]'::jsonb))
    with ordinality as x(item, ordem);

  select coalesce(
    jsonb_agg(
      case
        when item->>'id' = v_pessoa->>'id' then item
        else item || jsonb_build_object('funcao', null)
      end
      order by ordem
    ),
    '[]'::jsonb
  )
  into v_responsaveis
  from jsonb_array_elements(coalesce(v_resultado->'responsaveis', '[]'::jsonb))
    with ordinality as x(item, ordem);

  return v_resultado || jsonb_build_object(
    'funcao_cortejo', nullif(trim(coalesce(v_pessoa->>'funcao', '')), ''),
    'instrucoes_cortejo', '[]'::jsonb,
    'manuais', '[]'::jsonb,
    'pode_gerenciar', coalesce((v_pessoa->>'pode_gerenciar')::boolean, false),
    'convidados', v_convidados,
    'responsaveis', v_responsaveis
  );
end $$;

revoke all on function public.buscar_convite_037(text) from public;
revoke all on function public.buscar_convite_037(text) from anon, authenticated;
revoke all on function public.buscar_convite(text) from public;
grant execute on function public.buscar_convite(text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;

