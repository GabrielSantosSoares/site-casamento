# Gabriel & Alanna — site do casamento

Aplicação Next.js para convites individuais e coletivos, confirmação de
presença, cortejo, lista de presentes, pagamentos e gestão do evento.

## Publicação na Vercel

O projeto deve ficar diretamente na raiz do repositório. Na Vercel, use:

- Framework Preset: `Next.js`;
- Root Directory: vazio ou `./`;
- Node.js: `22.x`;
- Build Command: padrão (`npm run build`).

Configure estas variáveis sem gravar valores no repositório:

```text
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SECRET_KEY=
ADMIN_SETUP_KEY=
MP_CREDENTIAL_ENCRYPTION_KEY=
```

`ADMIN_SETUP_KEY` protege a criação da primeira senha do usuário `admin`.
`MP_CREDENTIAL_ENCRYPTION_KEY` deve ser uma chave Base64 aleatória de 32 bytes.

As credenciais do Mercado Pago são informadas apenas no painel administrativo.
O webhook deve apontar para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

## Banco de dados

Para um banco novo, execute somente:

```text
supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql
```

Para um banco existente que já recebeu as migrações anteriores, execute:

```text
supabase/migration_033_revisao_geral_perfis_notificacoes.sql
```

A expiração das reservas é executada pelo Supabase Cron. O arquivo
`vercel.json` não agenda tarefas na Vercel.

## Validação local

```bash
npm ci
npm run lint
npm test
npm run build
```
