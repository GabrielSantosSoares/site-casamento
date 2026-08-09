-- Cada assessora recebe um conjunto técnico próprio com perfil de assessoria.
-- O acesso privilegiado passa a ser resolvido pelo código individual da pessoa.

create or replace function public.gerar_codigo_conjunto()
returns text language plpgsql security definer set search_path=public as $$
declare v text;
begin
  loop
    v:=upper(substr(md5(gen_random_uuid()::text),1,6));
    exit when not exists(select 1 from public.convites where codigo=v);
  end loop;
  return v;
end; $$;

create or replace function public.preparar_perfil_assessoria()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_perfil text; v_convite uuid; v_codigo text;
begin
  if lower(coalesce(new.funcao,'')) in ('assessora','assessor') then
    select perfil_acesso into v_perfil from public.convites where id=new.convite_id;
    if coalesce(v_perfil,'')<>'assessoria' then
      v_codigo:=public.gerar_codigo_conjunto();
      insert into public.convites(
        codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,manuais,ativo
      ) values(
        v_codigo,'Assessoria — '||new.nome,'Assessora',3,'assessoria','{}',true
      ) returning id into v_convite;
      new.convite_id:=v_convite;
      new.pode_gerenciar:=true;
      new.principal:=false;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_preparar_perfil_assessoria on public.convidados;
create trigger trg_preparar_perfil_assessoria
before insert or update of funcao on public.convidados
for each row execute function public.preparar_perfil_assessoria();

-- Corrige assessoras já adicionadas em conjuntos comuns.
do $$
declare r record; v_convite uuid;
begin
  for r in
    select g.id,g.nome from public.convidados g join public.convites c on c.id=g.convite_id
    where lower(coalesce(g.funcao,'')) in ('assessora','assessor')
      and c.perfil_acesso<>'assessoria'
  loop
    insert into public.convites(
      codigo,nome_familia,funcao_cortejo,nivel_acesso,perfil_acesso,manuais,ativo
    ) values(
      public.gerar_codigo_conjunto(),'Assessoria — '||r.nome,'Assessora',3,'assessoria','{}',true
    ) returning id into v_convite;
    update public.convidados set convite_id=v_convite,pode_gerenciar=true,principal=false
      where id=r.id;
  end loop;
end $$;

create or replace function public.configurar_senha_noivos(p_codigo text,p_senha text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  if length(p_senha)<8 then return false; end if;
  select c.id into v_convite_id from public.convidados g
  join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_convite_id is null then
    select id into v_convite_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_convite_id is null then return false; end if;
  update public.convites set senha_hash=crypt(p_senha,gen_salt('bf')),atualizado_em=now()
    where id=v_convite_id and senha_hash is null;
  return found;
end; $$;

create or replace function public.criar_sessao_noivos(
  p_codigo text,p_senha text,p_token_hash text
) returns boolean language plpgsql security definer set search_path=public as $$
declare v_convite_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select c.id into v_convite_id from public.convidados g
  join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin')
    and c.senha_hash is not null and c.senha_hash=crypt(p_senha,c.senha_hash);
  if v_convite_id is null then
    select id into v_convite_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin'
      and senha_hash is not null and senha_hash=crypt(p_senha,senha_hash);
  end if;
  if v_convite_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_convite_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

grant execute on function public.configurar_senha_noivos(text,text) to anon,authenticated;
grant execute on function public.criar_sessao_noivos(text,text,text) to anon,authenticated;
notify pgrst,'reload schema';
