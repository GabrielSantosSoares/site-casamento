begin;

create or replace function public.importar_convidados_automatico(
  p_token_hash text,
  p_linhas jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb; v_codigo text; v_codigo_individual text; v_nome text;
  v_grupo text; v_funcao text; v_origem text; v_convite_id uuid;
  v_ordem integer; v_total integer := 0;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) not between 1 and 1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_grupo := nullif(trim(coalesce(v_item->>'grupo','')), '');
    v_funcao := nullif(trim(coalesce(v_item->>'funcao','')), '');
    v_origem := coalesce(v_item->>'origem','nao_classificado');
    if length(v_nome) < 2 or length(v_nome) > 150 or v_origem not in ('noivo','noiva','ambos','nao_classificado') then return -2; end if;

    v_convite_id := null;
    if v_grupo is not null then
      select id into v_convite_id from public.convites
      where ativo and lower(trim(nome_familia)) = lower(v_grupo)
      order by criado_em limit 1;
    end if;
    if v_convite_id is null then
      loop
        v_codigo := upper(substr(md5(gen_random_uuid()::text),1,6));
        exit when not exists(select 1 from public.convites where codigo=v_codigo)
          and not exists(select 1 from public.convidados where codigo_individual=v_codigo);
      end loop;
      insert into public.convites(codigo,nome_familia,nivel_acesso,perfil_acesso,ativo)
      values(v_codigo,coalesce(v_grupo,v_nome),1,'convidado',true) returning id into v_convite_id;
    end if;

    loop
      v_codigo_individual := upper(substr(md5(gen_random_uuid()::text),1,6));
      exit when not exists(select 1 from public.convites where codigo=v_codigo_individual)
        and not exists(select 1 from public.convidados where codigo_individual=v_codigo_individual);
    end loop;
    select coalesce(max(ordem),0)+1 into v_ordem from public.convidados where convite_id=v_convite_id;
    insert into public.convidados(convite_id,nome,principal,pode_gerenciar,ordem,funcao,codigo_individual,origem)
    values(v_convite_id,v_nome,v_ordem=1,v_ordem=1,v_ordem,v_funcao,v_codigo_individual,v_origem);
    v_total := v_total + 1;
  end loop;
  return v_total;
exception when unique_violation or invalid_text_representation or not_null_violation then return -2;
end $$;

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
  v_ordem integer; v_total integer := 0;
begin
  if not exists (
    select 1 from public.sessoes_organizacao s
    join public.organizacao o on o.id = s.organizacao_id
    where s.token_hash = p_token_hash and s.expira_em > now() and o.ativo
      and (o.administrador or o.funcao in ('noivo','noiva'))
  ) then return -1; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) not between 1 and 1000 then return -2; end if;

  for v_item in select * from jsonb_array_elements(p_linhas) loop
    v_nome := trim(coalesce(v_item->>'nome',''));
    v_categoria := trim(coalesce(v_item->>'categoria',''));
    v_descricao := nullif(trim(coalesce(v_item->>'descricao','')), '');
    v_valor := (v_item->>'valor')::numeric;
    v_quantidade := greatest(1, least(10000, coalesce((v_item->>'quantidade')::integer,1)));
    select coalesce(array_agg(value), '{}') into v_imagens from jsonb_array_elements_text(coalesce(v_item->'links_fotos','[]'::jsonb));
    if length(v_nome)<2 or length(v_nome)>150 or length(v_categoria)<2 or v_valor<0 or cardinality(v_imagens)>10 then return -2; end if;

    select id into v_categoria_id from public.categorias_presentes where lower(trim(nome))=lower(v_categoria) order by ativo desc, ordem limit 1;
    if v_categoria_id is null then
      select coalesce(max(ordem),0)+1 into v_ordem from public.categorias_presentes;
      insert into public.categorias_presentes(nome,ordem) values(v_categoria,v_ordem) returning id into v_categoria_id;
    else
      update public.categorias_presentes set ativo=true where id=v_categoria_id;
    end if;
    select coalesce(max(ordem),0)+1 into v_ordem from public.presentes;
    insert into public.presentes(nome,descricao,preco_centavos,quantidade_total,ordem,categoria_id,imagens)
    values(v_nome,v_descricao,round(v_valor*100)::integer,v_quantidade,v_ordem,v_categoria_id,v_imagens);
    v_total := v_total + 1;
  end loop;
  return v_total;
exception when invalid_text_representation or numeric_value_out_of_range or not_null_violation then return -2;
end $$;

revoke all on function public.importar_convidados_automatico(text,jsonb) from public;
revoke all on function public.importar_presentes_automatico(text,jsonb) from public;
grant execute on function public.importar_convidados_automatico(text,jsonb) to anon,authenticated;
grant execute on function public.importar_presentes_automatico(text,jsonb) to anon,authenticated;

notify pgrst, 'reload schema';
commit;
