-- Códigos individuais de acesso para cada convidado.
-- Esta migração histórica estava ausente do pacote, embora as migrações 008+
-- já dependessem da coluna convidados.codigo_individual.

alter table public.convidados
  add column if not exists codigo_individual varchar(6);

create or replace function public.gerar_codigo_individual_unico()
returns varchar
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo varchar(6);
begin
  loop
    v_codigo := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (
      select 1 from public.convites where codigo = v_codigo
    ) and not exists (
      select 1 from public.convidados where codigo_individual = v_codigo
    );
  end loop;
  return v_codigo;
end;
$$;

-- Preenche instalações antigas e corrige códigos nulos, inválidos ou repetidos
-- antes de aplicar as garantias definitivas da coluna.
do $$
declare
  v_id uuid;
begin
  for v_id in
    select id
    from (
      select
        id,
        codigo_individual,
        row_number() over (
          partition by codigo_individual
          order by criado_em, id
        ) as repeticao
      from public.convidados
    ) codigos
    where codigo_individual is null
       or codigo_individual !~ '^[A-Z0-9]{6}$'
       or repeticao > 1
  loop
    update public.convidados
       set codigo_individual = public.gerar_codigo_individual_unico()
     where id = v_id;
  end loop;
end;
$$;

alter table public.convidados
  alter column codigo_individual
    set default public.gerar_codigo_individual_unico(),
  alter column codigo_individual set not null;

alter table public.convidados
  drop constraint if exists convidados_codigo_individual_formato_check;

alter table public.convidados
  add constraint convidados_codigo_individual_formato_check
  check (
    codigo_individual = upper(codigo_individual)
    and codigo_individual ~ '^[A-Z0-9]{6}$'
  );

create unique index if not exists convidados_codigo_individual_unico
  on public.convidados (codigo_individual);

revoke all on function public.gerar_codigo_individual_unico() from public;
grant execute on function public.gerar_codigo_individual_unico() to service_role;

notify pgrst, 'reload schema';
