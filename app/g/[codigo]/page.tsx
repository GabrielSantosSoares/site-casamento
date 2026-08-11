import { redirect } from "next/navigation";
import AplicacaoCasamento from "../../../componentes/AplicacaoCasamento";
import {
  carregarAcessoInicial,
  carregarEventoPublicoInicial,
  codigoIndividualDoConviteUnitario,
} from "../../../lib/dados-iniciais";

export const dynamic = "force-dynamic";

export default async function ConviteDoGrupo({
  params,
  searchParams,
}: {
  params: Promise<{ codigo: string }>;
  searchParams: Promise<{ pagamento?: string }>;
}) {
  const [{ codigo }, busca] = await Promise.all([params, searchParams]);
  const codigoInicial = codigo.trim().toUpperCase();
  const individual = await codigoIndividualDoConviteUnitario(codigoInicial);
  if (individual) {
    const pagamento = busca.pagamento
      ? `?pagamento=${encodeURIComponent(busca.pagamento)}`
      : "";
    redirect(`/c/${individual}${pagamento}`);
  }
  const [eventoInicial, acessoInicial] = await Promise.all([
    carregarEventoPublicoInicial(),
    carregarAcessoInicial(codigoInicial),
  ]);
  return (
    <AplicacaoCasamento
      eventoInicial={eventoInicial}
      acessoInicial={acessoInicial}
      codigoInicial={codigoInicial}
      somenteGrupoInicial
      pagamentoInicial={busca.pagamento ?? null}
    />
  );
}
