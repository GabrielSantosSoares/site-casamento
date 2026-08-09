-- Edição das imagens dos presentes pelo dashboard dos noivos e administradores.

create or replace function public.administrar_imagens_presente(
  p_token_hash text,
  p_presente_id uuid,
  p_imagens text[]
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permitido boolean;
  v_url text;
begin
  select exists(
    select 1
    from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash
      and s.expira_em > now()
      and o.ativo
      and (o.administrador or o.funcao in ('noivo', 'noiva'))
  ) into v_permitido;

  if not v_permitido or cardinality(coalesce(p_imagens, '{}')) > 10 then
    return false;
  end if;

  foreach v_url in array coalesce(p_imagens, '{}') loop
    if length(v_url) > 1000 or v_url !~* '^https?://' then
      return false;
    end if;
  end loop;

  update public.presentes
  set imagens = coalesce(p_imagens, '{}')
  where id = p_presente_id;

  return found;
end;
$$;

revoke all on function public.administrar_imagens_presente(text, uuid, text[]) from public;
grant execute on function public.administrar_imagens_presente(text, uuid, text[]) to anon, authenticated;

notify pgrst, 'reload schema';
