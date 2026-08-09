-- O backend Next.js passa a gerar e verificar Argon2id.
-- Estas funções NÃO são públicas: exigem a chave secreta/service-role.

create or replace function public.resolver_acesso_backend(p_codigo text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return null; end if;
  return jsonb_build_object(
    'convite_id',c.id,'perfil',c.perfil_acesso,
    'senha_hash',c.senha_hash,'senha_criada',c.senha_hash is not null
  );
end; $$;

create or replace function public.salvar_hash_argon2_backend(p_codigo text,p_hash text)
returns text language plpgsql security definer set search_path=public as $$
declare c public.convites%rowtype;
begin
  if p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$' then return 'hash_invalido'; end if;
  select cv.* into c from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if not found then
    select * into c from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if not found then return 'sem_acesso'; end if;
  if c.senha_hash is not null then return 'ja_criada'; end if;
  update public.convites set senha_hash=p_hash,atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

create or replace function public.criar_sessao_backend(p_codigo text,p_token_hash text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  delete from public.sessoes_noivos where expira_em<=now();
  select cv.id into v_id from public.convidados g join public.convites cv on cv.id=g.convite_id
  where g.codigo_individual=upper(trim(p_codigo)) and cv.ativo=true
    and cv.perfil_acesso in ('noivos','assessoria','admin');
  if v_id is null then
    select id into v_id from public.convites
    where codigo=upper(trim(p_codigo)) and ativo=true and perfil_acesso='admin';
  end if;
  if v_id is null then return false; end if;
  insert into public.sessoes_noivos(convite_id,token_hash,expira_em)
    values(v_id,p_token_hash,now()+interval '7 days');
  return true;
end; $$;

revoke all on function public.resolver_acesso_backend(text) from public,anon,authenticated;
revoke all on function public.salvar_hash_argon2_backend(text,text) from public,anon,authenticated;
revoke all on function public.criar_sessao_backend(text,text) from public,anon,authenticated;
grant execute on function public.resolver_acesso_backend(text) to service_role;
grant execute on function public.salvar_hash_argon2_backend(text,text) to service_role;
grant execute on function public.criar_sessao_backend(text,text) to service_role;

-- Hashes bcrypt antigos não podem ser verificados pelo novo backend sem receber a senha no banco.
-- Exige criação de uma nova senha Argon2id no próximo acesso e encerra sessões antigas.
update public.convites set senha_hash=null,atualizado_em=now()
where perfil_acesso in ('noivos','assessoria','admin')
  and senha_hash is not null and senha_hash not like '$argon2id$%';
delete from public.sessoes_noivos;
notify pgrst,'reload schema';
