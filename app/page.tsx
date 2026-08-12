import { EventInfo, SiteCasamento } from "../componentes/SiteCasamento";

export const dynamic = "force-dynamic";

const EVENTO_PUBLICO_PADRAO: EventInfo = {
  data: "2026-10-03",
  hora: "18:30",
  cidade: "Candeias-BA",
  local_liberado: false,
  nome_espaco: "",
  endereco: "",
  link_maps: null,
};

function somenteDadosPublicos(valor: unknown): EventInfo {
  const evento =
    valor && typeof valor === "object"
      ? (valor as Partial<EventInfo>)
      : EVENTO_PUBLICO_PADRAO;
  return {
    data: /^\d{4}-\d{2}-\d{2}$/.test(String(evento.data ?? ""))
      ? String(evento.data)
      : EVENTO_PUBLICO_PADRAO.data,
    hora: /^\d{2}:\d{2}$/.test(String(evento.hora ?? ""))
      ? String(evento.hora)
      : EVENTO_PUBLICO_PADRAO.hora,
    cidade: String(evento.cidade ?? EVENTO_PUBLICO_PADRAO.cidade).slice(0, 120),
    local_liberado: false,
    nome_espaco: "",
    endereco: "",
    link_maps: null,
  };
}

async function carregarEventoPublico(): Promise<EventInfo> {
  const url = process.env.SUPABASE_URL;
  const chave = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !chave) return EVENTO_PUBLICO_PADRAO;
  try {
    const resposta = await fetch(`${url}/rest/v1/rpc/evento_publico`, {
      method: "POST",
      headers: { apikey: chave, "Content-Type": "application/json" },
      body: "{}",
      cache: "no-store",
    });
    if (!resposta.ok) return EVENTO_PUBLICO_PADRAO;
    return somenteDadosPublicos(await resposta.json());
  } catch {
    return EVENTO_PUBLICO_PADRAO;
  }
}

export default async function Home() {
  return <SiteCasamento eventoInicial={await carregarEventoPublico()} />;
}
