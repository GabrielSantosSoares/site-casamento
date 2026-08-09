# Site de casamento — Gabriel e Alanna

Aplicação Next.js com Supabase e integração Mercado Pago, preparada para
publicação pelo GitHub e pela Vercel.

## Desenvolvimento local

```bash
npm ci
cp .env.example .env.local
npm run dev
```

Preencha `.env.local` com as credenciais do seu ambiente. Esse arquivo é
ignorado pelo Git.

## Produção

Consulte [GUIA_PUBLICACAO.md](./GUIA_PUBLICACAO.md).

## Banco de dados

Em um banco novo, execute:

```text
supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql
```

Em um banco que já recebeu a migração 033, execute somente:

```text
supabase/migration_034_codigos_organizacao_login.sql
```

A migração 034 permite escolher e alterar o código de integrantes da
organização. A rotina de reservas vencidas usa o Supabase Cron configurado pela
migração 032; este pacote não cria um cron adicional na Vercel.
