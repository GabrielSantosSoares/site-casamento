# Gabriel & Alanna — site do casamento

Aplicação pública e administrativa para convites individuais e de grupo,
confirmação de presença, cortejo, lista de presentes, pagamentos e gestão do
evento.

## Áreas da aplicação

- `/` — página pública e entrada por código;
- `/c/CODIGO` — convite individual;
- `/g/CODIGO` — convite de grupo em modo de consulta;
- `/x` — acesso da organização por usuário ou código (o primeiro cadastro é
  reservado ao administrador principal);
- `/lista` — controle de chegada para noivos, organização e administração;
- `/politica-de-privacidade` — política usada no consentimento de CPF.

Os perfis da organização ficam separados dos convidados e aceitam funções
personalizadas. Pais dos noivos recebem o mesmo nível de acesso da assessoria.
Somente um código individual marcado como responsável pode confirmar presenças
ou adicionar crianças ao grupo.

## Variáveis de ambiente

Configure no ambiente de hospedagem, sem gravar valores no repositório:

```text
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SECRET_KEY=
ADMIN_SETUP_KEY=
MP_CREDENTIAL_ENCRYPTION_KEY=
```

`ADMIN_SETUP_KEY` protege exclusivamente a criação da primeira senha do usuário
`admin`. Use um valor longo e aleatório. `MP_CREDENTIAL_ENCRYPTION_KEY` protege
o Access Token do Mercado Pago e os CPFs armazenados.

## Banco de dados

Para um banco novo, execute no SQL Editor do Supabase:

```text
supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql
```

Para atualizar uma instalação que já recebeu as migrações anteriores, execute:

```text
supabase/migration_033_revisao_geral_perfis_notificacoes.sql
supabase/migration_034_codigos_organizacao_login.sql
supabase/migration_035_grupos_integrados_convidados.sql
supabase/migration_036_modelos_duplicidades_gestao_presentes.sql
supabase/migration_037_edicao_presentes_entregas_ilimitados.sql
supabase/migration_038_funcoes_individuais_manuais_criancas.sql
supabase/migration_039_responsaveis_criancas_trajes.sql
supabase/migration_040_retorno_pagamentos_convites_unitarios.sql
supabase/migration_041_privacidade_local_cortejo_organizacao_checkin.sql
```

As migrações 033 a 041 corrigem permissões dos perfis, confirmação por
responsável, sessões de logout, redefinição temporária de senha, notificações,
proteção dos códigos individuais, códigos da organização, grupos integrados,
duplicidades na importação e cadastro/remoção manual de presentes. Novas senhas
temporárias têm oito dígitos, e os acessos antigos de seis dígitos continuam
aceitos até a troca obrigatória. A migração 041 também protege o endereço na
página pública, habilita funções livres da organização, reconhece os perfis dos
pais, adiciona o aviso de presença e cria o controle de chegada. A instalação
completa já contém todas essas migrações.

## Desenvolvimento e validação

Requer Node.js 22.13 ou superior.

```bash
npm ci
npm run lint
npm test
```

`npm test` executa a análise estática, gera o build nativo do Next.js e roda a
suíte de regressão.

## Publicação no GitHub e Vercel

1. Envie o conteúdo desta pasta para um repositório GitHub.
2. Importe o repositório na Vercel; o framework Next.js será detectado.
3. Cadastre na Vercel as variáveis listadas em `.env.example`.
4. Em uma instalação existente, execute a migração `041` no SQL Editor do
   Supabase. Para um banco vazio, execute somente o instalador completo.

Não exponha `SUPABASE_SECRET_KEY`, `ADMIN_SETUP_KEY` ou
`MP_CREDENTIAL_ENCRYPTION_KEY` no navegador ou no repositório.

## Pagamentos

As credenciais do Mercado Pago são informadas somente no painel administrativo
e cifradas no banco. O webhook deve apontar para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

Reservas pendentes são conciliadas pelo Supabase Cron; boletos permanecem
pendentes até compensação ou atualização do provedor.
