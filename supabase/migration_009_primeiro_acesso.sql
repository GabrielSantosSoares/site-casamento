-- Estado e criação de senha com resultado explícito para noivos, assessoria e administrador.
create or replace function public.estado_acesso(p_codigo text)
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
  return jsonb_build_object('perfil',c.perfil_acesso,'senha_criada',c.senha_hash is not null);
end; $$;

create or replace function public.criar_senha_inicial(p_codigo text,p_senha text)
returns text language plpgsql security definer set search_path=public as $$
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
  update public.convites set senha_hash=crypt(p_senha,gen_salt('bf')),atualizado_em=now()
    where id=c.id and senha_hash is null;
  if found then return 'criada'; end if;
  return 'ja_criada';
end; $$;

grant execute on function public.estado_acesso(text) to anon,authenticated;
grant execute on function public.criar_senha_inicial(text,text) to anon,authenticated;
notify pgrst,'reload schema';
