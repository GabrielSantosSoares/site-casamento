# Publicação — Gabriel e Alanna

Este pacote foi preparado para GitHub + Vercel e não contém credenciais reais.

## 1. Enviar ao GitHub

1. Extraia o ZIP.
2. Crie um repositório privado no GitHub.
3. Envie o conteúdo extraído, deixando `package.json` na raiz.
4. Não envie `.env.local` nem qualquer arquivo com credenciais.

## 2. Criar o projeto na Vercel

1. Na Vercel, escolha **Add New > Project**.
2. Importe o repositório privado.
3. Confirme **Framework Preset: Next.js** e **Root Directory: `./`**.
4. Cadastre as variáveis de ambiente antes do primeiro deploy.

## 3. Variáveis de ambiente

Cadastre para **Production**, **Preview** e **Development**:

| Nome | Onde obter | Secreta? |
|---|---|---|
| `SUPABASE_URL` | Supabase > Project Settings > API | Não |
| `SUPABASE_PUBLISHABLE_KEY` | Supabase > Project Settings > API | Não |
| `SUPABASE_SECRET_KEY` | Supabase > Project Settings > API | Sim |
| `ADMIN_SETUP_KEY` | Gere uma chave inicial longa e aleatória | Sim |
| `MP_CREDENTIAL_ENCRYPTION_KEY` | Use a mesma chave forte já configurada | Sim |

`ADMIN_SETUP_KEY` é usada somente para criar a primeira senha do usuário
principal `admin`. Não altere `MP_CREDENTIAL_ENCRYPTION_KEY` depois que as
credenciais do Mercado Pago forem salvas, pois ela protege dados já cifrados.

O Access Token do Mercado Pago é salvo cifrado pela tela administrativa e não
deve ser inserido diretamente nas variáveis da Vercel.

## 4. Banco Supabase

Faça um backup antes de aplicar migrações.

- Banco novo: execute `supabase/INSTALACAO_COMPLETA_BANCO_NOVO.sql`.
- Banco já atualizado até a migração 033: execute
  `supabase/migration_034_codigos_organizacao_login.sql`.
- Banco anterior à migração 033: execute as migrações pendentes em ordem,
  terminando pela 034.

A expiração automática de reservas é executada pelo Supabase Cron configurado
na migração 032. Não é necessário configurar cron na Vercel.

## 5. Primeiro deploy e login

Depois de cadastrar as variáveis, faça o deploy e teste:

- `/x`: primeiro cadastro do `admin`; depois, login da organização por usuário
  ou código;
- código da organização + senha temporária na entrada pública;
- troca obrigatória da senha temporária após o login;
- criação e alteração de códigos de integrantes na página **Organização**;
- lista de convidados em computador e celular.

Senhas temporárias novas têm oito dígitos. Senhas temporárias antigas de seis
dígitos continuam aceitas até serem substituídas.

## 6. Domínio e Mercado Pago

Em **Vercel > Settings > Domains**, adicione o domínio e copie exatamente os
registros DNS indicados. Depois, atualize no painel administrativo do site a
URL-base definitiva com `https://`.

No Mercado Pago, configure o webhook para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

Teste pagamento, retorno e webhook antes de divulgar o domínio ou imprimir os
QR Codes definitivos.
