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
- `/lista` — controle de entrada para a organização;
- `/politica-de-privacidade` — política usada no consentimento de CPF.

Os perfis de organização (`administrador`, `noivo`, `noiva`, `assessoria` e os
quatro perfis de pais dos noivos) ficam separados dos convidados. Os pais podem
administrar convidados, grupos e integrantes não protegidos da organização,
sem receber acesso às configurações financeiras do administrador principal.

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
supabase/migration_042_pais_convites_grupos_controle_entrada.sql
```

As migrações 033 a 037 corrigem permissões dos perfis, confirmação por
responsável, sessões de logout, redefinição temporária de senha, notificações,
proteção dos códigos individuais, códigos da organização, grupos integrados,
duplicidades na importação e cadastro/remoção manual de presentes. Novas senhas
temporárias têm oito dígitos, e os acessos antigos de seis dígitos continuam
aceitos até a troca obrigatória. A instalação completa já contém todas essas
migrações. A migração 042 habilita os perfis dos pais, a associação de pessoas
existentes a grupos, a transformação em convite individual e o controle de
entrada. Ela também corrige as permissões necessárias para esses fluxos.

## Desenvolvimento e validação

Requer Node.js 22.13 ou superior.

```bash
npm ci
npm run lint
npm test
```

`npm test` executa a análise estática e os testes de regressão. `npm run build`
gera o artefato nativo do Next.js usado pela Vercel.

## Publicação no GitHub e na Vercel

1. Envie o conteúdo desta pasta para um repositório GitHub.
2. Importe o repositório na Vercel com o preset **Next.js**.
3. Cadastre na Vercel as variáveis listadas em `.env.example`.
4. Execute no Supabase a migração 042, ou o instalador completo em um banco novo.
5. Publique. A Vercel usará automaticamente `npm run build` com o compilador
   Webpack compatível com este projeto.

## Pagamentos

As credenciais do Mercado Pago são informadas somente no painel administrativo
e cifradas no banco. O webhook deve apontar para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

Reservas pendentes são conciliadas pelo Supabase Cron; boletos permanecem
pendentes até compensação ou atualização do provedor.
