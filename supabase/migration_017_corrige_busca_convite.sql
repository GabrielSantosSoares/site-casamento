-- Corrige a consulta pública de convites após a separação da organização.
-- A coluna convites.manuais é text[] e precisa ser convertida para jsonb.

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_convite public.convites%rowtype;
  v_org public.organizacao%rowtype;
begin
  select *
  into v_org
  from public.organizacao
  where codigo = upper(trim(p_codigo))
    and ativo;

  if found then
    return jsonb_build_object(
      'codigo', v_org.codigo,
      'codigo_conjunto', v_org.codigo,
      'nome_familia', v_org.nome,
      'funcao_cortejo', v_org.funcao,
      'instrucoes_cortejo', '[]'::jsonb,
      'convidados', '[]'::jsonb,
      'nivel_acesso', 3,
      'perfil_acesso',
        case
          when v_org.funcao in ('noivo', 'noiva') then 'noivos'
          else 'assessoria'
        end,
      'manuais', '[]'::jsonb,
      'senha_criada', v_org.senha_hash is not null,
      'exige_troca_senha', v_org.exige_troca_senha,
      'pode_gerenciar', true,
      'responsaveis', '[]'::jsonb,
      'expira_em', null,
      'expirado', false,
      'sem_expiracao', true
    );
  end if;

  select *
  into v_convite
  from public.convites
  where id = coalesce(
    (
      select convite_id
      from public.convidados
      where codigo_individual = upper(trim(p_codigo))
      limit 1
    ),
    (
      select id
      from public.convites
      where codigo = upper(trim(p_codigo))
      limit 1
    )
  )
    and ativo;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'codigo', upper(trim(p_codigo)),
    'codigo_conjunto', v_convite.codigo,
    'nome_familia', v_convite.nome_familia,
    'funcao_cortejo', v_convite.funcao_cortejo,
    'instrucoes_cortejo', v_convite.instrucoes_cortejo,
    'nivel_acesso', v_convite.nivel_acesso,
    'perfil_acesso', 'convidado',
    'manuais', to_jsonb(coalesce(v_convite.manuais, '{}'::text[])),
    'senha_criada', false,
    'exige_troca_senha', false,
    'expira_em', v_convite.expira_em,
    'sem_expiracao', v_convite.sem_expiracao,
    'expirado',
      (
        not v_convite.sem_expiracao
        and v_convite.expira_em <= now()
      ),
    'pode_gerenciar',
      coalesce(
        (
          select pode_gerenciar
          from public.convidados
          where codigo_individual = upper(trim(p_codigo))
          limit 1
        ),
        false
      ),
    'responsaveis',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', g.id,
              'nome', g.nome,
              'funcao', g.funcao
            )
          )
          from public.convidados g
          where g.convite_id = v_convite.id
            and g.pode_gerenciar
        ),
        '[]'::jsonb
      ),
    'convidados',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', g.id,
              'nome', g.nome,
              'codigo_individual', g.codigo_individual,
              'pode_gerenciar', g.pode_gerenciar,
              'funcao', g.funcao,
              'status', cf.status
            )
            order by g.ordem, g.nome
          )
          from public.convidados g
          left join public.confirmacoes cf
            on cf.convidado_id = g.id
          where g.convite_id = v_convite.id
        ),
        '[]'::jsonb
      )
  );
end;
$$;

revoke all
on function public.buscar_convite(text)
from public;

grant execute
on function public.buscar_convite(text)
to anon, authenticated;

notify pgrst, 'reload schema';
