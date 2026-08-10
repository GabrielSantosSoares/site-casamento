"use client";

import { useMemo, useState } from "react";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import QRCode from "qrcode";

type Pessoa = {
  id: string;
  convite_id: string;
  nome: string;
  codigo: string;
  codigo_individual: string;
  conjunto: string;
  funcao: string | null;
  status: "confirmado" | "aguardando" | "expirado";
  expira_em: string | null;
};
type Evento = { data: string; hora: string; cidade: string; local_liberado: boolean; nome_espaco: string; endereco: string };
type Configuracoes = { url_base: string; mensagem_confirmacao: string };
type Modo = "individuais" | "grupos" | "ambos";
type TamanhoPapel = "a4" | "a5";
type DisposicaoA5 = "paginas_individuais" | "dois_em_a4";
type TipoConvite = "pre_convite" | "convite";

const A4_RETRATO: [number, number] = [595.28, 841.89];
const A5_RETRATO: [number, number] = [419.53, 595.28];
const A4_PAISAGEM: [number, number] = [841.89, 595.28];

const normalizar = (valor: string) => valor.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const dataDoEvento = (data: string) => {
  const segura = /^\d{4}-\d{2}-\d{2}$/.test(data) ? data : "2026-10-03";
  return new Intl.DateTimeFormat("pt-BR", {
    day: "2-digit",
    month: "long",
    year: "numeric",
  })
    .format(new Date(`${segura}T12:00:00`))
    .toLocaleUpperCase("pt-BR");
};
const quebrar = (texto: string, limite = 66) => {
  const palavras = texto.split(/\s+/);
  const linhas: string[] = [];
  let atual = "";
  for (const palavra of palavras) {
    if (`${atual} ${palavra}`.trim().length > limite) {
      linhas.push(atual);
      atual = palavra;
    } else atual = `${atual} ${palavra}`.trim();
  }
  if (atual) linhas.push(atual);
  return linhas;
};

type PaginaConvite = { titulo: string; pessoas: Pessoa[]; url: string; codigo: string };

function montarPaginas(
  pessoas: Pessoa[],
  selecionados: Set<string>,
  modo: Modo,
  base: string,
): PaginaConvite[] {
  const marcados = pessoas.filter((p) => selecionados.has(p.id));
  const paginas: PaginaConvite[] = [];

  if (modo === "individuais" || modo === "ambos") {
    for (const pessoa of marcados) {
      paginas.push({
        titulo: pessoa.nome,
        pessoas: [pessoa],
        url: `${base}/c/${pessoa.codigo_individual}`,
        codigo: pessoa.codigo_individual,
      });
    }
  }

  if (modo === "grupos" || modo === "ambos") {
    // Combina os identificadores disponíveis. Alguns registros antigos podem
    // compartilhar convite_id indevidamente; o código distingue esses grupos
    // e impede que seleções diferentes sejam reduzidas ao primeiro convite.
    const gruposMarcados = new Map<string, Pessoa>();
    for (const pessoa of marcados) {
      const codigoGrupo = pessoa.codigo?.trim().toUpperCase();
      const chaveGrupo = codigoGrupo
        ? `codigo:${codigoGrupo}`
        : pessoa.convite_id
          ? `convite:${pessoa.convite_id}`
          : `conjunto:${normalizar(pessoa.conjunto)}`;
      gruposMarcados.set(chaveGrupo, pessoa);
    }

    for (const pessoaReferencia of gruposMarcados.values()) {
      const codigoGrupo = pessoaReferencia.codigo?.trim().toUpperCase();
      const membros = pessoas.filter((p) => codigoGrupo
        ? p.codigo?.trim().toUpperCase() === codigoGrupo
        : pessoaReferencia.convite_id
          ? p.convite_id === pessoaReferencia.convite_id
          : normalizar(p.conjunto) === normalizar(pessoaReferencia.conjunto),
      );
      const pessoasDoConvite = membros.length ? membros : [pessoaReferencia];
      const pessoaUnica = pessoasDoConvite.length === 1 ? pessoasDoConvite[0] : null;
      paginas.push({
        titulo: pessoaUnica?.nome ?? pessoasDoConvite[0]?.conjunto ?? pessoaReferencia.conjunto ?? "Convite",
        pessoas: pessoasDoConvite,
        url: pessoaUnica
          ? `${base}/c/${pessoaUnica.codigo_individual}`
          : `${base}/g/${pessoaReferencia.codigo}`,
        codigo: pessoaUnica?.codigo_individual ?? pessoaReferencia.codigo,
      });
    }
  }

  return paginas;
}

export function ExportarConvites({ pessoas, evento, configuracoes }: { pessoas: Pessoa[]; evento: Evento; configuracoes: Configuracoes }) {
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set());
  const [nome, setNome] = useState("");
  const [grupo, setGrupo] = useState("");
  const [funcao, setFuncao] = useState("");
  const [status, setStatus] = useState("");
  const [modo, setModo] = useState<Modo>("grupos");
  const [tamanhoPapel, setTamanhoPapel] = useState<TamanhoPapel>("a4");
  const [disposicaoA5, setDisposicaoA5] = useState<DisposicaoA5>("paginas_individuais");
  const [tipoConvite, setTipoConvite] = useState<TipoConvite>("pre_convite");
  const [gerando, setGerando] = useState(false);

  const grupos = useMemo(() => [...new Set(pessoas.map((p) => p.conjunto))].sort(), [pessoas]);
  const funcoes = useMemo(() => [...new Set(pessoas.map((p) => p.funcao).filter(Boolean) as string[])].sort(), [pessoas]);
  const filtrados = useMemo(() => pessoas.filter((p) =>
    (!nome || normalizar(`${p.nome} ${p.codigo_individual}`).includes(normalizar(nome)))
    && (!grupo || p.conjunto === grupo)
    && (!funcao || p.funcao === funcao)
    && (!status || p.status === status)
  ), [pessoas, nome, grupo, funcao, status]);
  const paginasPrevistas = useMemo(
    () => montarPaginas(pessoas, selecionados, modo, configuracoes.url_base.replace(/\/+$/, "")).length,
    [pessoas, selecionados, modo, configuracoes.url_base],
  );

  function alternar(id: string) {
    setSelecionados((atual) => {
      const proximo = new Set(atual);
      if (proximo.has(id)) proximo.delete(id); else proximo.add(id);
      return proximo;
    });
  }

  async function gerarPdf() {
    if (!selecionados.size) return;
    setGerando(true);
    try {
      const convitesPdf = await PDFDocument.create();
      const regular = await convitesPdf.embedFont(StandardFonts.Helvetica);
      const negrito = await convitesPdf.embedFont(StandardFonts.HelveticaBold);
      const monograma = await convitesPdf.embedPng(await fetch("/monograma-ga.png").then((resposta) => resposta.arrayBuffer()));
      const flores = await convitesPdf.embedPng(await fetch("/convite-flores.png").then((resposta) => resposta.arrayBuffer()));
      const base = configuracoes.url_base.replace(/\/+$/, "");
      const paginas = montarPaginas(pessoas, selecionados, modo, base);
      for (const item of paginas) {
        const page = convitesPdf.addPage(A4_RETRATO);
        const serenity = rgb(.53, .67, .79);
        const azulProfundo = rgb(.12, .23, .38);
        const oliva = rgb(.38, .43, .27);
        const dourado = rgb(.71, .57, .30);
        const brancoQuente = rgb(.995, .992, .98);
        const centro = 297.64;
        const centralizar = (texto: string, y: number, size: number, font = regular, color = azulProfundo) => {
          const largura = font.widthOfTextAtSize(texto, size);
          page.drawText(texto, { x: centro - largura / 2, y, size, font, color });
        };
        page.drawRectangle({ x: 0, y: 0, width: 595.28, height: 841.89, color: brancoQuente });
        page.drawImage(flores, { x: 0, y: 0, width: 595.28, height: 841.89, opacity: 1 });
        page.drawRectangle({ x: 24, y: 24, width: 547.28, height: 793.89, borderColor: dourado, borderWidth: 1.45 });
        page.drawRectangle({ x: 30, y: 30, width: 535.28, height: 781.89, borderColor: dourado, borderWidth: .45, opacity: .65 });
        page.drawEllipse({ x: centro, y: 764, xScale: 43, yScale: 43, color: rgb(1, 1, 1), opacity: .96 });
        page.drawImage(monograma, { x: 261.5, y: 728, width: 72, height: 72 });
        centralizar("O QUE DEUS UNIU", 706, 9.5, negrito, dourado);
        page.drawLine({ start: { x: 220, y: 696 }, end: { x: 375, y: 696 }, thickness: .7, color: dourado, opacity: .72 });
        centralizar("Gabriel & Alanna", 656, 27, negrito, azulProfundo);
        centralizar("TÊM A ALEGRIA DE CONVIDAR", 610, 8.5, negrito, oliva);
        centralizar(item.titulo, 576, Math.min(18, 430 / Math.max(item.titulo.length, 1) * 1.8), negrito, azulProfundo);
        quebrar("Com muita alegria, convidamos você para celebrar conosco o início da nossa família. Sua presença tornará este dia ainda mais especial.", 76)
          .forEach((linha, i) => centralizar(linha, 553 - i * 13, 9, regular, azulProfundo));
        page.drawRectangle({ x: 108, y: 485, width: 379, height: 42, color: rgb(.93, .95, .98), borderColor: serenity, borderWidth: .5, opacity: .95 });
        centralizar(`${dataDoEvento(evento.data)}  •  ${evento.hora}`, 509, 11, negrito, azulProfundo);
        centralizar(evento.cidade.toUpperCase(), 492, 9, regular, oliva);
        if (tipoConvite === "convite" && evento.local_liberado) {
          centralizar(evento.nome_espaco, 466, 11, negrito, azulProfundo);
          quebrar(evento.endereco, 72).forEach((linha, i) => centralizar(linha, 450 - i * 14, 9, regular, oliva));
        }
        if (tipoConvite === "pre_convite") {
          const qr = await QRCode.toDataURL(item.url, { width: 360, margin: 1, errorCorrectionLevel: "H", color: { dark: "#203b61", light: "#ffffff" } });
          const png = await convitesPdf.embedPng(qr);
          page.drawRectangle({ x: 225, y: 294, width: 146, height: 146, color: rgb(1,1,1), borderColor: dourado, borderWidth: 1 });
          page.drawImage(png, { x: 236, y: 305, width: 124, height: 124 });
          centralizar(item.pessoas.length > 1 ? "ACESSO DO GRUPO" : "ACESSO DO CONVITE", 276, 8, negrito, dourado);
          centralizar(`CÓDIGO: ${item.codigo}`, 259, 12, negrito, azulProfundo);
          const prazo = item.pessoas.map((p) => p.expira_em).filter(Boolean).sort()[0];
          if (prazo) centralizar(`Confirme sua presença até ${new Date(prazo).toLocaleDateString("pt-BR")}.`, 239, 10, negrito, oliva);
          quebrar(configuracoes.mensagem_confirmacao || "Acesse pelo QR Code, informe seu código e confirme a presença.", 72)
            .forEach((linha, i) => centralizar(linha, 219 - i * 13, 9, regular, azulProfundo));
        } else {
          centralizar(`CÓDIGO DO CONVITE: ${item.codigo}`, 350, 12, negrito, azulProfundo);
          centralizar("Apresente este convite na recepção.", 328, 9, regular, oliva);
        }
        centralizar("“O que Deus uniu, ninguém separe.”", 190, 10, regular, azulProfundo);
        centralizar("Mateus 19:6", 175, 8, negrito, dourado);
        if (tipoConvite === "pre_convite" && item.pessoas.length > 1) {
          centralizar("ACESSOS INDIVIDUAIS", 153, 8, negrito, dourado);
          for (const [i,p] of item.pessoas.slice(0,6).entries()) {
            const qrPessoa=await QRCode.toDataURL(`${base}/c/${p.codigo_individual}`,{width:200,margin:1,errorCorrectionLevel:"H",color:{dark:"#203b61",light:"#ffffff"}});
            const pngPessoa=await convitesPdf.embedPng(qrPessoa);
            const coluna=i%3,linha=Math.floor(i/3),x=49+coluna*174,y=88-linha*61;
            page.drawRectangle({x:x-3,y:y-2,width:169,height:62,color:rgb(1,1,1),opacity:.88});
            page.drawImage(pngPessoa,{x,y,width:60,height:60});
            page.drawText(p.nome.slice(0,18),{x:x+66,y:y+34,size:7,font:regular,color:azulProfundo});
            page.drawText(p.codigo_individual,{x:x+62,y:y+18,size:9,font:negrito,color:oliva});
          }
        }
      }
      let bytes: Uint8Array;
      if (tamanhoPapel === "a4") {
        bytes = await convitesPdf.save();
      } else {
        const baseBytes = await convitesPdf.save();
        const pdfFinal = await PDFDocument.create();
        // O pdf-lib incorpora somente a primeira página quando `indices` é
        // omitido. Informe todas explicitamente para preservar a exportação
        // em lote ao converter os convites A4 para A5.
        const indicesDasPaginas = Array.from(
          { length: convitesPdf.getPageCount() },
          (_, indice) => indice,
        );
        const paginasBase = await pdfFinal.embedPdf(baseBytes, indicesDasPaginas);
        const escala = A5_RETRATO[0] / A4_RETRATO[0];
        const alturaConvite = A4_RETRATO[1] * escala;
        const ajusteY = (A5_RETRATO[1] - alturaConvite) / 2;

        if (disposicaoA5 === "paginas_individuais") {
          for (const convite of paginasBase) {
            const page = pdfFinal.addPage(A5_RETRATO);
            page.drawPage(convite, { x: 0, y: ajusteY, xScale: escala, yScale: escala });
          }
        } else {
          for (let indice = 0; indice < paginasBase.length; indice += 2) {
            const page = pdfFinal.addPage(A4_PAISAGEM);
            const larguraMetade = A4_PAISAGEM[0] / 2;
            const ajusteX = (larguraMetade - A5_RETRATO[0]) / 2;
            page.drawPage(paginasBase[indice], { x: ajusteX, y: ajusteY, xScale: escala, yScale: escala });
            if (paginasBase[indice + 1]) {
              page.drawPage(paginasBase[indice + 1], { x: larguraMetade + ajusteX, y: ajusteY, xScale: escala, yScale: escala });
            }
            page.drawLine({
              start: { x: larguraMetade, y: 0 },
              end: { x: larguraMetade, y: A4_PAISAGEM[1] },
              thickness: 0.35,
              color: rgb(0.72, 0.72, 0.72),
              dashArray: [3, 3],
              opacity: 0.75,
            });
          }
        }
        bytes = await pdfFinal.save();
      }
      const blob = new Blob([new Uint8Array(bytes)], { type: "application/pdf" });
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      const formatoArquivo = tamanhoPapel === "a4" ? "a4" : disposicaoA5 === "dois_em_a4" ? "a5-duplo-a4-paisagem" : "a5-individual";
      link.download = `${tipoConvite}-${modo}-${formatoArquivo}-${new Date().toISOString().slice(0, 10)}.pdf`;
      link.click();
      URL.revokeObjectURL(link.href);
    } finally {
      setGerando(false);
    }
  }

  return <div className="panel admin-page">
    <p className="eyebrow">Convites impressos</p><h1>Exportar convites</h1>
    <p>Filtre a relação, marque quem receberá convite impresso e escolha o formato do PDF.</p>
    <fieldset className="print-mode"><legend>Tipo de material</legend>
      <label><input type="radio" name="tipo-convite" checked={tipoConvite === "pre_convite"} onChange={() => setTipoConvite("pre_convite")}/> Pré-convite — QR Code, cidade, data e mensagem</label>
      <label><input type="radio" name="tipo-convite" checked={tipoConvite === "convite"} onChange={() => setTipoConvite("convite")}/> Convite — sem QR Code, com código e local quando liberado</label>
    </fieldset>
    <div className="export-filters">
      <input type="search" value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Nome ou código"/>
      <select value={grupo} onChange={(e) => setGrupo(e.target.value)}><option value="">Todos os grupos</option>{grupos.map((g) => <option key={g}>{g}</option>)}</select>
      <select value={funcao} onChange={(e) => setFuncao(e.target.value)}><option value="">Todas as funções</option>{funcoes.map((f) => <option key={f}>{f}</option>)}</select>
      <select value={status} onChange={(e) => setStatus(e.target.value)}><option value="">Todos os status</option><option value="aguardando">Aguardando</option><option value="confirmado">Confirmado</option><option value="expirado">Expirado</option></select>
    </div>
    <div className="admin-actions">
      <button className="secondary" onClick={() => setSelecionados(new Set(filtrados.map((p) => p.id)))}>Marcar filtrados</button>
      <button className="secondary" onClick={() => setSelecionados(new Set())}>Limpar seleção</button>
      <span>{selecionados.size} selecionado(s)</span>
    </div>
    <div className="export-people">{filtrados.map((p) => <label key={p.id}><input type="checkbox" checked={selecionados.has(p.id)} onChange={() => alternar(p.id)}/><span><b>{p.nome}</b><small>{p.conjunto} · {p.funcao || "Convidado"} · {p.status}</small></span></label>)}</div>
    <fieldset className="print-mode"><legend>Formato dos convites</legend>
      <label><input type="radio" name="modo" checked={modo === "individuais"} onChange={() => setModo("individuais")}/> Individuais</label>
      <label><input type="radio" name="modo" checked={modo === "grupos"} onChange={() => setModo("grupos")}/> Grupo</label>
      <label><input type="radio" name="modo" checked={modo === "ambos"} onChange={() => setModo("ambos")}/> Ambos</label>
    </fieldset>
    <fieldset className="print-mode"><legend>Tamanho do papel</legend>
      <label><input type="radio" name="tamanho-papel" checked={tamanhoPapel === "a4"} onChange={() => setTamanhoPapel("a4")}/> A4 — um convite por página</label>
      <label><input type="radio" name="tamanho-papel" checked={tamanhoPapel === "a5"} onChange={() => setTamanhoPapel("a5")}/> A5</label>
    </fieldset>
    {tamanhoPapel === "a5" && <fieldset className="print-mode"><legend>Organização do A5</legend>
      <label><input type="radio" name="disposicao-a5" checked={disposicaoA5 === "paginas_individuais"} onChange={() => setDisposicaoA5("paginas_individuais")}/> Páginas A5 individuais</label>
      <label><input type="radio" name="disposicao-a5" checked={disposicaoA5 === "dois_em_a4"} onChange={() => setDisposicaoA5("dois_em_a4")}/> Folha A4 em paisagem com dois convites A5</label>
    </fieldset>}
    {!!selecionados.size && <p><b>{paginasPrevistas}</b> convite(s) serão incluídos no PDF.</p>}
    <button className="primary" disabled={!selecionados.size || gerando} onClick={gerarPdf}>{gerando ? "Gerando PDF..." : "Gerar PDF para impressão"}</button>
  </div>;
}
