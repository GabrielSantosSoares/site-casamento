-- Imagens dos itens da lista de presentes.
-- Cada presente pode ter uma ou mais URLs; o site usa a imagem padrão
-- quando o campo está vazio ou quando a imagem externa não carrega.

alter table public.presentes
add column if not exists imagens text[] not null default '{}';

create or replace function public.listar_presentes()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'nome', p.nome,
        'descricao', p.descricao,
        'imagens', coalesce(p.imagens, '{}'),
        'preco_centavos', p.preco_centavos,
        'quantidade_total', p.quantidade_total,
        'quantidade_assinada', coalesce(r.assinada, 0),
        'quantidade_restante',
          greatest(p.quantidade_total - coalesce(r.assinada, 0), 0)
      )
      order by p.ordem, p.nome
    ),
    '[]'::jsonb
  )
  from public.presentes p
  left join (
    select
      presente_id,
      sum(quantidade)::integer as assinada
    from public.reservas_presentes
    where status = 'confirmado'
    group by presente_id
  ) r on r.presente_id = p.id
  where p.ativo = true;
$$;

revoke all
on function public.listar_presentes()
from public;

grant execute
on function public.listar_presentes()
to anon, authenticated;

notify pgrst, 'reload schema';

