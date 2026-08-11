import AplicacaoCasamento from "../componentes/AplicacaoCasamento";
import { carregarEventoPublicoInicial } from "../lib/dados-iniciais";

export const dynamic = "force-dynamic";

export default async function Home() {
  const eventoInicial = await carregarEventoPublicoInicial();
  return <AplicacaoCasamento eventoInicial={eventoInicial} />;
}
