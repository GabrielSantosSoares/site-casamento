# Site de casamento — Gabriel e Alanna

Aplicação Next.js com Supabase e Mercado Pago, preparada para GitHub e Vercel.

## Desenvolvimento local

Requer Node.js 22.

```bash
npm ci
cp .env.example .env.local
npm run dev
```

Preencha `.env.local` com as credenciais do seu ambiente. Esse arquivo não
deve ser enviado ao GitHub.

## Validação

```bash
npm run lint
npm test
npm run build
```

## Banco de dados

- Banco novo: execute somente
  `supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql`.
- Banco existente: execute apenas as migrações ainda não aplicadas, em ordem
  numérica.
- Para ativar a versão mais recente de “Minha função”, execute as migrações
  `038` e `039`, nessa ordem, caso ainda não tenham sido aplicadas.

A expiração de reservas é executada pelo Supabase Cron, configurado pela
migração 032. Este pacote não cria um Cron adicional na Vercel.

## Publicação

Consulte [GUIA_PUBLICACAO.md](./GUIA_PUBLICACAO.md).
