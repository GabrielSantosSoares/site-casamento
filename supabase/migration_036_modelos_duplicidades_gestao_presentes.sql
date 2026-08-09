begin;

-- Evita duplicidades acidentais na importação. Uma repetição só é inserida
-- quando foi revisada e marcada explicitamente como outro item pela interface.
create or replace function public.importar_presentes_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb; v_nome text; v_categoria text; v_categoria_id uuid;
  v_descricao text; v_imagens text[]; v_valor numeric; v_quantidade integer;
  v_ordem integer; v_total integer := 0; v_permitir_duplicado boolean;
  v_nome_normalizado text;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array'
    or jsonb_array_length(p_linhas) not between 1 and 1000
  then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_categoria := trim(coalesce(v_item->>'categoria',''));
    v_descricao := nullif(trim(coalesce(v_item->>'descricao','')), '');
    v_valor := (v_item->>'valor')::numeric;
    v_quantidade := greatest(
      1,
      least(10000, coalesce((v_item->>'quantidade')::integer,1))
    );
    v_permitir_duplicado := coalesce(
      (v_item->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value), '{}') into v_imagens
    from jsonb_array_elements_text(
      coalesce(v_item->'links_fotos','[]'::jsonb)
    );
    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2
      or v_valor<0 or v_valor>1000000 or cardinality(v_imagens)>10
      or exists(
        select 1 from unnest(v_imagens) imagem
        where imagem !~* '^https?://'
      )
    then return -2; end if;

    v_nome_normalizado := lower(
      regexp_replace(trim(v_nome), '[[:space:]]+', ' ', 'g')
    );
    if not v_permitir_duplicado and exists (
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome), '[[:space:]]+', ' ', 'g'))
          = v_nome_normalizado
    ) then
      continue;
    end if;

    select id into v_categoria_id
    from public.categorias_presentes
    where lower(trim(nome))=lower(v_categoria)
    order by ativo desc, ordem
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
    v_total := v_total + 1;
  end loop;
  return v_total;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation
  then return -2;
end $$;

-- Cadastro manual e remoção segura. A exclusão é lógica para que assinaturas,
-- pagamentos e auditoria continuem íntegros mesmo após o item sair da lista.
create or replace function public.administrar_presente_dashboard(
  p_token_hash text,
  p_acao text,
  p_dados jsonb
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid; v_nome text; v_descricao text; v_categoria_id uuid;
  v_preco_centavos integer; v_quantidade_total integer; v_imagens text[];
  v_ordem integer; v_permitir_duplicado boolean; v_nome_normalizado text;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id=s.organizacao_id
    where s.token_hash=p_token_hash and s.expira_em>now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return false; end if;

  if p_acao='criar' then
    v_nome:=trim(coalesce(p_dados->>'nome',''));
    v_descricao:=nullif(trim(coalesce(p_dados->>'descricao','')),'');
    v_categoria_id:=nullif(p_dados->>'categoria_id','')::uuid;
    v_preco_centavos:=(p_dados->>'preco_centavos')::integer;
    v_quantidade_total:=(p_dados->>'quantidade_total')::integer;
    v_permitir_duplicado:=coalesce(
      (p_dados->>'permitir_duplicado')::boolean,
      false
    );
    select coalesce(array_agg(value), '{}') into v_imagens
    from jsonb_array_elements_text(coalesce(p_dados->'imagens','[]'::jsonb));

    if length(v_nome) not between 2 and 150
      or coalesce(length(v_descricao),0)>1000
      or v_preco_centavos not between 0 and 100000000
      or v_quantidade_total not between 1 and 10000
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
      regexp_replace(trim(v_nome), '[[:space:]]+', ' ', 'g')
    );
    if not v_permitir_duplicado and exists (
      select 1 from public.presentes p
      where p.ativo
        and lower(regexp_replace(trim(p.nome), '[[:space:]]+', ' ', 'g'))
          = v_nome_normalizado
    ) then return false; end if;

    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(
      nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens
    ) values(
      v_nome,v_descricao,v_preco_centavos,v_quantidade_total,v_ordem,
      v_categoria_id,v_imagens
    );
    return true;
  elsif p_acao='excluir' then
    v_id:=nullif(p_dados->>'id','')::uuid;
    update public.presentes set ativo=false
    where id=v_id and ativo;
    return found;
  end if;
  return false;
exception
  when invalid_text_representation or numeric_value_out_of_range
    or not_null_violation or check_violation or unique_violation
  then return false;
end $$;

revoke all on function public.importar_presentes_automatico(text,jsonb)
  from public;
revoke all on function public.administrar_presente_dashboard(text,text,jsonb)
  from public;
grant execute on function public.importar_presentes_automatico(text,jsonb)
  to anon,authenticated;
grant execute on function public.administrar_presente_dashboard(text,text,jsonb)
  to anon,authenticated;

notify pgrst,'reload schema';
commit;
