import AplicacaoCasamento from "../../../componentes/AplicacaoCasamento";
import {
  carregarAcessoInicial,
  carregarEventoPublicoInicial,
} from "../../../lib/dados-iniciais";

export const dynamic = "force-dynamic";

export default async function ConviteIndividual({
  params,
  searchParams,
}: {
  params: Promise<{ codigo: string }>;
  searchParams: Promise<{ pagamento?: string }>;
}) {
  const [{ codigo }, busca] = await Promise.all([params, searchParams]);
  const codigoInicial = codigo.trim().toUpperCase();
  const [eventoInicial, acessoInicial] = await Promise.all([
    carregarEventoPublicoInicial(),
    carregarAcessoInicial(codigoInicial),
  ]);
  return (
    <AplicacaoCasamento
      eventoInicial={eventoInicial}
      acessoInicial={acessoInicial}
      codigoInicial={codigoInicial}
      pagamentoInicial={busca.pagamento ?? null}
    />
  );
}
