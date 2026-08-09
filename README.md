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
- `/politica-de-privacidade` — política usada no consentimento de CPF.

Os perfis de organização (`administrador`, `noivo`, `noiva` e `assessoria`)
ficam separados dos convidados. Apenas um código individual marcado como
responsável pode confirmar presenças ou adicionar crianças ao grupo.

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
```

As migrações 033 a 036 corrigem permissões dos perfis, confirmação por
responsável, sessões de logout, redefinição temporária de senha, notificações,
proteção dos códigos individuais, códigos da organização, grupos integrados,
duplicidades na importação e cadastro/remoção manual de presentes. Novas senhas
temporárias têm oito dígitos, e os acessos antigos de seis dígitos continuam
aceitos até a troca obrigatória. A instalação completa já contém todas essas
migrações.

## GitHub e Vercel

O pacote usa Next.js nativo e Node.js 22.x. Envie os arquivos diretamente para
a raiz do repositório e configure na Vercel as variáveis listadas em
`.env.example`.

```bash
npm ci
npm run lint
npm run build
```

O processamento automático de reservas é executado pelo Supabase Cron; não há
Cron da Vercel nem variável `CRON_SECRET`.

## Pagamentos

As credenciais do Mercado Pago são informadas somente no painel administrativo
e cifradas no banco. O webhook deve apontar para:

```text
https://SEU-DOMINIO/api/mercado-pago/webhook
```

Reservas pendentes são conciliadas pelo Supabase Cron; boletos permanecem
pendentes até compensação ou atualização do provedor.
