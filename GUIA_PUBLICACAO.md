# Publicação no GitHub e na Vercel

Este pacote está preparado para Next.js na Vercel e não contém credenciais
reais.

## 1. GitHub

1. Extraia o ZIP.
2. Envie o conteúdo extraído para a raiz do repositório, de forma que
   `package.json` fique na raiz.
3. Não envie `.env.local` nem qualquer arquivo com credenciais.

## 2. Vercel

1. Importe o repositório do GitHub.
2. Confirme o preset **Next.js**.
3. Mantenha o diretório raiz como `./`.
4. Use Node.js 22.
5. Cadastre as variáveis abaixo em Production, Preview e Development:

| Variável | Observação |
|---|---|
| `SUPABASE_URL` | URL do projeto Supabase |
| `SUPABASE_PUBLISHABLE_KEY` | Chave pública do Supabase |
| `SUPABASE_SECRET_KEY` | Chave secreta, somente no servidor |
| `ADMIN_SETUP_KEY` | Chave forte para o primeiro acesso do administrador |
| `MP_CREDENTIAL_ENCRYPTION_KEY` | Chave forte e permanente para cifrar dados |

O Access Token do Mercado Pago é salvo cifrado pelo próprio painel
administrativo e não deve ser colocado diretamente no repositório.

## 3. Supabase

- Banco novo: execute somente
  `supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql`.
- Banco existente: execute somente as migrações ainda não aplicadas.
- Para a atualização mais recente das funções e dos responsáveis por crianças,
  aplique `migration_038_funcoes_individuais_manuais_criancas.sql` e depois
  `migration_039_responsaveis_criancas_trajes.sql`.

A rotina de reservas vencidas usa o Supabase Cron da migração 032. Não
configure um Cron equivalente na Vercel.

## 4. Mercado Pago

Depois de publicar, configure o webhook para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

Atualize também a URL-base no painel administrativo do site.

## 5. Verificação final

- acesso individual, por grupo e da organização;
- confirmação de presença;
- “Minha função”, responsáveis e downloads dos manuais;
- presentes físicos, doações e confirmação de entrega;
- pagamentos e webhook do Mercado Pago;
- painéis administrativo, dos noivos e da assessoria;
- geração de convites e QR Codes;
- funcionamento em celular e computador.
