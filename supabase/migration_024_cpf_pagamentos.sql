begin;

alter table public.integracoes_pagamento
  add column if not exists recolher_cpf boolean not null default false,
  add column if not exists cpf_valor_minimo_centavos integer not null default 35000;

alter table public.integracoes_pagamento
  drop constraint if exists integracoes_pagamento_cpf_minimo_check;

alter table public.integracoes_pagamento
  add constraint integracoes_pagamento_cpf_minimo_check
  check (cpf_valor_minimo_centavos between 1 and 100000000);

alter table public.reservas_presentes
  add column if not exists doador_chave text,
  add column if not exists cpf_cifrado text,
  add column if not exists cpf_consentimento_em timestamptz,
  add column if not exists cpf_politica_versao text;

-- Permite que pagamentos aprovados anteriores à migração também participem
-- do total acumulado do convite.
update public.reservas_presentes
set doador_chave = 'convite:' || convite_id::text
where meio = 'mercado_pago'
  and doador_chave is null;

create index if not exists reservas_doador_pagamentos_idx
  on public.reservas_presentes (doador_chave, status, meio)
  where meio = 'mercado_pago';

comment on column public.reservas_presentes.cpf_cifrado is
  'CPF criptografado pela aplicação; nunca armazenar em texto simples.';

alter table public.integracoes_pagamento enable row level security;
alter table public.reservas_presentes enable row level security;

notify pgrst, 'reload schema';

commit;
