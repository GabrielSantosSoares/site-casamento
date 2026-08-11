-- Privacidade do local, aviso de confirmação, funções livres da organização,
-- perfis de pais, visão do cortejo e controle de entrada do evento.
begin;

alter table public.convidados
  add column if not exists aviso_eleicoes_lido_em timestamptz,
  add column if not exists chegada_confirmada_em timestamptz,
  add column if not exists chegada_confirmada_por uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.convidados'::regclass
      and conname = 'convidados_chegada_confirmada_por_fkey'
  ) then
    alter table public.convidados
      add constraint convidados_chegada_confirmada_por_fkey
      foreign key (chegada_confirmada_por)
      references public.organizacao(id)
      on delete set null;
  end if;
end $$;

create index if not exists convidados_chegada_confirmada_idx
  on public.convidados (chegada_confirmada_em, convite_id);

-- Remove o limite antigo de quatro funções fixas. A função continua obrigatória,
-- curta e validada, mas pode ser criada livremente pelo painel.
alter table public.organizacao
  drop constraint if exists organizacao_funcao_check,
  drop constraint if exists organizacao_funcao_texto_check;

alter table public.organizacao
  add constraint organizacao_funcao_texto_check
  check (length(trim(funcao)) between 2 and 80);

create or replace function public.normalizar_funcao_organizacao(p_funcao text)
returns text
language sql
immutable
set search_path = public
as $$
  select lower(translate(
    trim(coalesce(p_funcao, '')),
    'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc'
  ));
$$;

create or replace function public.perfil_funcao_organizacao(
  p_funcao text,
  p_administrador boolean
) returns text
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(p_administrador, false) then 'admin'
    when public.normalizar_funcao_organizacao(p_funcao) in ('noivo', 'noiva')
      then 'noivos'
    when public.normalizar_funcao_organizacao(p_funcao) in (
      'assessoria', 'assessor', 'assessora',
      'pai do noivo', 'mae do noivo', 'pai da noiva', 'mae da noiva'
    ) then 'assessoria'
    else 'organizacao'
  end;
$$;

create or replace function public.evento_publico()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'data', to_char(data_evento, 'YYYY-MM-DD'),
    'hora', to_char(hora_evento, 'HH24:MI'),
    'cidade', cidade
  )
  from public.configuracao_evento
  where id = true;
$$;

create or replace function public.evento_interno()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'data', to_char(data_evento, 'YYYY-MM-DD'),
    'hora', to_char(hora_evento, 'HH24:MI'),
    'cidade', cidade,
    'local_liberado', local_liberado,
    'nome_espaco', nome_espaco,
    'endereco', endereco,
    'link_maps', link_maps
  )
  from public.configuracao_evento
  where id = true;
$$;

create or replace function public.estado_organizacao(p_identificador text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.organizacao%rowtype;
begin
  select * into v
  from public.organizacao
  where ativo
    and (
      lower(usuario) = lower(trim(p_identificador))
      or codigo = upper(trim(p_identificador))
    );
  if not found then return null; end if;
  return jsonb_build_object(
    'nome', v.nome,
    'funcao', v.funcao,
    'perfil', public.perfil_funcao_organizacao(v.funcao, v.administrador),
    'senha_criada', v.senha_hash is not null,
    'exige_troca_senha', v.exige_troca_senha,
    'codigo', v.codigo
  );
end $$;

do $$
begin
  if to_regprocedure('public.buscar_convite_040(text)') is null then
    alter function public.buscar_convite(text) rename to buscar_convite_040;
  end if;
  if to_regprocedure('public.dashboard_noivos_040(text)') is null then
    alter function public.dashboard_noivos(text) rename to dashboard_noivos_040;
  end if;
end $$;

create or replace function public.buscar_convite(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resultado jsonb;
  v_org public.organizacao%rowtype;
  v_aviso_lido boolean := false;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
begin
  select public.buscar_convite_040(p_codigo) into v_resultado;
  if v_resultado is null then return null; end if;

  select * into v_org
  from public.organizacao
  where ativo and codigo = v_codigo
  limit 1;

  if found then
    return v_resultado || jsonb_build_object(
      'perfil_acesso', public.perfil_funcao_organizacao(
        v_org.funcao,
        v_org.administrador
      ),
      'funcao_cortejo', v_org.funcao,
      'aviso_eleicoes_lido', true,
      'evento', public.evento_interno()
    );
  end if;

  select g.aviso_eleicoes_lido_em is not null into v_aviso_lido
  from public.convidados g
  where g.codigo_individual = v_codigo
  limit 1;

  return v_resultado || jsonb_build_object(
    'aviso_eleicoes_lido', coalesce(v_aviso_lido, false),
    'evento', public.evento_interno()
  );
end $$;

create or replace function public.confirmar_leitura_aviso_eleicoes(p_codigo text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
begin
  update public.convidados g
  set aviso_eleicoes_lido_em = coalesce(g.aviso_eleicoes_lido_em, now())
  from public.convites c
  where c.id = g.convite_id
    and c.ativo
    and g.codigo_individual = v_codigo
    and g.pode_gerenciar;
  return found;
end $$;

create or replace function public.dashboard_noivos(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_ator public.organizacao%rowtype;
  v_perfil text;
  v_pode_gerir boolean;
  v_organizacao jsonb;
begin
  select o.* into v_ator
  from public.sessoes_organizacao s
  join public.organizacao o on o.id = s.organizacao_id
  where s.token_hash = p_token_hash
    and s.expira_em > now()
    and o.ativo;
  if not found then return null; end if;

  select public.dashboard_noivos_040(p_token_hash) into v_base;
  if v_base is null then return null; end if;

  v_perfil := public.perfil_funcao_organizacao(
    v_ator.funcao,
    v_ator.administrador
  );
  v_pode_gerir := v_perfil in ('admin', 'noivos', 'assessoria');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', o.id,
    'nome', o.nome,
    'usuario', o.usuario,
    'codigo', o.codigo,
    'funcao', o.funcao,
    'administrador', o.administrador,
    'principal', o.principal,
    'senha_criada', o.senha_hash is not null,
    'exige_troca_senha', o.exige_troca_senha,
    'perfil_acesso', public.perfil_funcao_organizacao(o.funcao, o.administrador),
    'pode_editar', case
      when o.principal or o.id = v_ator.id then false
      when v_perfil = 'admin' then true
      when v_pode_gerir and public.perfil_funcao_organizacao(
        o.funcao,
        o.administrador
      ) not in ('admin', 'noivos') then true
      else false
    end,
    'pode_excluir', case
      when o.principal or o.id = v_ator.id then false
      when v_perfil = 'admin' then true
      when v_pode_gerir and public.perfil_funcao_organizacao(
        o.funcao,
        o.administrador
      ) not in ('admin', 'noivos') then true
      else false
    end
  ) order by o.principal desc, o.nome), '[]'::jsonb)
  into v_organizacao
  from public.organizacao o
  where o.ativo;

  return v_base || jsonb_build_object(
    'perfil', v_perfil,
    'conta', coalesce(v_base->'conta', '{}'::jsonb) || jsonb_build_object(
      'id', v_ator.id,
      'nome', v_ator.nome,
      'usuario', v_ator.usuario,
      'funcao', v_ator.funcao,
      'principal', v_ator.principal,
      'exige_troca_senha', v_ator.exige_troca_senha
    ),
    'organizacao', v_organizacao,
    'evento', public.evento_interno()
  );
end $$;

create or replace function public.administrar_organizacao_backend(
  p_token_hash text,
  p_acao text,
  p_dados jsonb,
  p_hash text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ator public.organizacao%rowtype;
  v_alvo public.organizacao%rowtype;
  v_perfil_ator text;
  v_perfil_alvo text;
  v_codigo text;
  v_usuario text;
  v_nome text;
  v_funcao text;
  v_administrador boolean;
begin
  select o.* into v_ator
  from public.sessoes_organizacao s
  join public.organizacao o on o.id = s.organizacao_id
  where s.token_hash = p_token_hash
    and s.expira_em > now()
    and o.ativo;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'acesso_negado');
  end if;

  v_perfil_ator := public.perfil_funcao_organizacao(
    v_ator.funcao,
    v_ator.administrador
  );
  if v_perfil_ator not in ('admin', 'noivos', 'assessoria') then
    return jsonb_build_object('ok', false, 'motivo', 'acesso_negado');
  end if;

  v_usuario := lower(trim(coalesce(p_dados->>'usuario', '')));
  v_nome := trim(coalesce(p_dados->>'nome', ''));
  v_funcao := trim(coalesce(p_dados->>'funcao', ''));
  v_administrador := case
    when v_perfil_ator = 'admin'
      then coalesce((p_dados->>'administrador')::boolean, false)
    else false
  end;
  v_codigo := upper(trim(coalesce(p_dados->>'codigo', '')));

  if p_acao = 'criar' then
    if v_usuario = 'admin'
      or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or length(v_funcao) not between 2 and 80
      or p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then
      return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
    end if;
    if v_perfil_ator <> 'admin'
      and public.perfil_funcao_organizacao(v_funcao, v_administrador)
        in ('admin', 'noivos')
    then
      return jsonb_build_object('ok', false, 'motivo', 'funcao_protegida');
    end if;
    if exists (
      select 1 from public.organizacao where lower(usuario) = v_usuario
    ) then
      return jsonb_build_object('ok', false, 'motivo', 'usuario_indisponivel');
    end if;

    if v_codigo = '' then
      loop
        v_codigo := upper(substr(md5(gen_random_uuid()::text), 1, 6));
        perform pg_advisory_xact_lock(hashtext(v_codigo));
        exit when not exists (
          select 1 from public.organizacao where codigo = v_codigo
        ) and not exists (
          select 1 from public.convites where codigo = v_codigo
        ) and not exists (
          select 1 from public.convidados where codigo_individual = v_codigo
        );
      end loop;
    else
      if v_codigo !~ '^[A-Z0-9]{6}$' then
        return jsonb_build_object('ok', false, 'motivo', 'codigo_invalido');
      end if;
      perform pg_advisory_xact_lock(hashtext(v_codigo));
      if exists (select 1 from public.organizacao where codigo = v_codigo)
        or exists (select 1 from public.convites where codigo = v_codigo)
        or exists (
          select 1 from public.convidados where codigo_individual = v_codigo
        )
      then
        return jsonb_build_object('ok', false, 'motivo', 'codigo_indisponivel');
      end if;
    end if;

    insert into public.organizacao (
      usuario, codigo, nome, funcao, administrador, senha_hash,
      exige_troca_senha
    ) values (
      v_usuario, v_codigo, v_nome, v_funcao, v_administrador, p_hash, true
    );
    return jsonb_build_object('ok', true, 'codigo', v_codigo);
  end if;

  begin
    select * into v_alvo
    from public.organizacao
    where id = nullif(p_dados->>'id', '')::uuid
      and ativo;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
  end;
  if v_alvo.id is null then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrado');
  end if;
  if v_alvo.principal or v_alvo.id = v_ator.id then
    return jsonb_build_object('ok', false, 'motivo', 'acesso_negado');
  end if;

  v_perfil_alvo := public.perfil_funcao_organizacao(
    v_alvo.funcao,
    v_alvo.administrador
  );
  if v_perfil_ator <> 'admin' and v_perfil_alvo in ('admin', 'noivos') then
    return jsonb_build_object('ok', false, 'motivo', 'funcao_protegida');
  end if;

  if p_acao = 'editar' then
    if v_usuario = 'admin'
      or v_usuario !~ '^[a-z0-9._-]{3,40}$'
      or length(v_nome) not between 2 and 150
      or length(v_funcao) not between 2 and 80
    then
      return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
    end if;
    if v_perfil_ator <> 'admin'
      and public.perfil_funcao_organizacao(v_funcao, v_administrador)
        in ('admin', 'noivos')
    then
      return jsonb_build_object('ok', false, 'motivo', 'funcao_protegida');
    end if;
    if v_codigo !~ '^[A-Z0-9]{6}$' then
      return jsonb_build_object('ok', false, 'motivo', 'codigo_invalido');
    end if;
    perform pg_advisory_xact_lock(hashtext(v_codigo));
    if exists (
      select 1 from public.organizacao
      where lower(usuario) = v_usuario and id <> v_alvo.id
    ) then
      return jsonb_build_object('ok', false, 'motivo', 'usuario_indisponivel');
    end if;
    if exists (
      select 1 from public.organizacao
      where codigo = v_codigo and id <> v_alvo.id
    ) or exists (
      select 1 from public.convites where codigo = v_codigo
    ) or exists (
      select 1 from public.convidados where codigo_individual = v_codigo
    ) then
      return jsonb_build_object('ok', false, 'motivo', 'codigo_indisponivel');
    end if;

    update public.organizacao
    set nome = v_nome,
        usuario = v_usuario,
        codigo = v_codigo,
        funcao = v_funcao,
        administrador = v_administrador,
        atualizado_em = now()
    where id = v_alvo.id;
    return jsonb_build_object('ok', true, 'codigo', v_codigo);
  elsif p_acao in ('resetar_senha', 'definir_senha') then
    if p_hash is null
      or p_hash !~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$'
    then
      return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
    end if;
    update public.organizacao
    set senha_hash = p_hash,
        exige_troca_senha = true,
        atualizado_em = now()
    where id = v_alvo.id;
    delete from public.sessoes_organizacao
    where organizacao_id = v_alvo.id;
    return jsonb_build_object('ok', true, 'codigo', v_alvo.codigo);
  elsif p_acao = 'excluir' then
    delete from public.organizacao where id = v_alvo.id;
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
exception
  when unique_violation or check_violation or not_null_violation
    or invalid_text_representation then
    return jsonb_build_object('ok', false, 'motivo', 'dados_invalidos');
end $$;

create or replace function public.listar_controle_acesso(
  p_token_hash text,
  p_busca text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ator public.organizacao%rowtype;
  v_perfil text;
  v_busca text := trim(coalesce(p_busca, ''));
  v_pessoas jsonb;
  v_total integer;
  v_presentes integer;
  v_faltantes integer;
begin
  select o.* into v_ator
  from public.sessoes_organizacao s
  join public.organizacao o on o.id = s.organizacao_id
  where s.token_hash = p_token_hash
    and s.expira_em > now()
    and o.ativo;
  if not found then return null; end if;

  v_perfil := public.perfil_funcao_organizacao(
    v_ator.funcao,
    v_ator.administrador
  );

  select
    count(*)::integer,
    count(*) filter (where g.chegada_confirmada_em is not null)::integer,
    count(*) filter (
      where cf.status = 'sim' and g.chegada_confirmada_em is null
    )::integer
  into v_total, v_presentes, v_faltantes
  from public.convidados g
  join public.convites c on c.id = g.convite_id
  left join public.confirmacoes cf on cf.convidado_id = g.id
  where c.ativo
    and c.perfil_acesso not in ('noivos', 'assessoria', 'admin');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'nome', g.nome,
    'codigo_individual', g.codigo_individual,
    'grupo', c.nome_familia,
    'codigo_grupo', c.codigo,
    'funcao', g.funcao,
    'resposta', cf.status,
    'chegada_confirmada_em', g.chegada_confirmada_em,
    'chegada_confirmada_por', quem.nome
  ) order by g.nome), '[]'::jsonb)
  into v_pessoas
  from public.convidados g
  join public.convites c on c.id = g.convite_id
  left join public.confirmacoes cf on cf.convidado_id = g.id
  left join public.organizacao quem on quem.id = g.chegada_confirmada_por
  where c.ativo
    and c.perfil_acesso not in ('noivos', 'assessoria', 'admin')
    and (
      v_busca = ''
      or g.codigo_individual = upper(v_busca)
      or c.codigo = upper(v_busca)
      or g.nome ilike '%' || v_busca || '%'
    );

  return jsonb_build_object(
    'perfil', v_perfil,
    'conta', jsonb_build_object('nome', v_ator.nome, 'funcao', v_ator.funcao),
    'total', v_total,
    'presentes', v_presentes,
    'faltantes', v_faltantes,
    'pessoas', v_pessoas
  );
end $$;

create or replace function public.confirmar_chegada_evento(
  p_token_hash text,
  p_convidado_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ator public.organizacao%rowtype;
  v_pessoa_nome text;
  v_chegada timestamptz;
begin
  select o.* into v_ator
  from public.sessoes_organizacao s
  join public.organizacao o on o.id = s.organizacao_id
  where s.token_hash = p_token_hash
    and s.expira_em > now()
    and o.ativo;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'acesso_negado');
  end if;

  select g.nome, g.chegada_confirmada_em
  into v_pessoa_nome, v_chegada
  from public.convidados g
  join public.convites c on c.id = g.convite_id
  where g.id = p_convidado_id
    and c.ativo
    and c.perfil_acesso not in ('noivos', 'assessoria', 'admin');
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'convidado_invalido');
  end if;
  if v_chegada is not null then
    return jsonb_build_object('ok', false, 'motivo', 'ja_confirmada');
  end if;

  update public.convidados
  set chegada_confirmada_em = now(),
      chegada_confirmada_por = v_ator.id
  where id = p_convidado_id
    and chegada_confirmada_em is null;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'ja_confirmada');
  end if;

  insert into public.auditoria_administrativa (
    ator, perfil, acao, entidade, detalhes
  ) values (
    v_ator.nome,
    public.perfil_funcao_organizacao(v_ator.funcao, v_ator.administrador),
    'confirmar_chegada',
    'convidados',
    jsonb_build_object('convidado_id', p_convidado_id, 'nome', v_pessoa_nome)
  );

  return jsonb_build_object(
    'ok', true,
    'convidado_id', p_convidado_id,
    'nome', v_pessoa_nome
  );
end $$;

revoke all on function public.normalizar_funcao_organizacao(text) from public;
revoke all on function public.perfil_funcao_organizacao(text, boolean) from public;
revoke all on function public.evento_publico() from public;
revoke all on function public.evento_interno() from public;
revoke all on function public.buscar_convite_040(text) from public, anon, authenticated;
revoke all on function public.dashboard_noivos_040(text) from public, anon, authenticated;
revoke all on function public.administrar_organizacao_backend(text, text, jsonb, text)
  from public, anon, authenticated;
revoke all on function public.buscar_convite(text) from public;
revoke all on function public.dashboard_noivos(text) from public;
revoke all on function public.confirmar_leitura_aviso_eleicoes(text) from public;
revoke all on function public.listar_controle_acesso(text, text) from public;
revoke all on function public.confirmar_chegada_evento(text, uuid) from public;

grant execute on function public.administrar_organizacao_backend(
  text, text, jsonb, text
) to service_role;

grant execute on function public.buscar_convite(text),
  public.evento_publico(),
  public.dashboard_noivos(text),
  public.confirmar_leitura_aviso_eleicoes(text),
  public.listar_controle_acesso(text, text),
  public.confirmar_chegada_evento(text, uuid)
to anon, authenticated;

notify pgrst, 'reload schema';
commit;
