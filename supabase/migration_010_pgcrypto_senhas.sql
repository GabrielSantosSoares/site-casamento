-- Corrige o acesso ao pgcrypto nas funções SECURITY DEFINER.
create or replace function public.criar_senha_inicial(p_codigo text,p_senha text)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare c public.convites%rowtype;
begin
  if length(p_senha)<8 or length(p_senha)>128 then return 'senha_invalida'; end if;
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return 'sem_acesso'; end if;
  if c.senha_hash is not null then return 'ja_criada'; end if;
  update public.convites
    set senha_hash=extensions.crypt(p_senha,extensions.gen_salt('bf')),atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

create or replace function public.configurar_senha_noivos(p_codigo text,p_senha text)
returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare v_id uuid;
begin
  if length(p_senha)<8 or length(p_senha)>128 then return false; end if;
  select c.id into v_id from public.convidados g join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin');
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_id is null then return false; end if;
  update public.convites
    set senha_hash=extensions.crypt(p_senha,extensions.gen_salt('bf')),atualizado_em=now()
    where id=v_id and senha_hash is null;
  return found;
end; $$;

create or replace function public.criar_sessao_noivos(
  p_codigo text,p_senha text,p_token_hash text
) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare v_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select c.id into v_id from public.convidados g join public.convites c on c.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and c.ativo=true
    and c.perfil_acesso in ('noivos','assessoria','admin')
    and c.senha_hash is not null
    and c.senha_hash=extensions.crypt(p_senha,c.senha_hash);
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin'
      and senha_hash is not null
      and senha_hash=extensions.crypt(p_senha,senha_hash);
  end if;
  if v_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

grant execute on function public.criar_senha_inicial(text,text) to anon,authenticated;
grant execute on function public.configurar_senha_noivos(text,text) to anon,authenticated;
grant execute on function public.criar_sessao_noivos(text,text,text) to anon,authenticated;
notify pgrst,'reload schema';
