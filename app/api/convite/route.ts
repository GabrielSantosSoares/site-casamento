import { NextRequest, NextResponse } from "next/server";
import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { argon2id } from "@noble/hashes/argon2.js";
import { ehCriancaDoCortejo } from "../../../lib/funcoes";

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_PUBLISHABLE_KEY;
const supabaseSecretKey = process.env.SUPABASE_SECRET_KEY;
const ARGON2_OPTIONS = { m: 19456, t: 2, p: 1, dkLen: 32 } as const;
const EVENTO_PADRAO = {
  data: "2026-10-03",
  hora: "18:30",
  cidade: "Candeias-BA",
  local_liberado: false,
  nome_espaco: "Espaço Brunus",
  endereco: "Rua Dário Sales, 31 - Centro, Candeias-BA, 43.805-000",
  link_maps: null,
};
type PainelAdministrativo = {
  perfil?: string;
  conta?: { nome?: string; usuario?: string };
};
type ConvidadoConviteRpc = {
  id: string;
  nome?: string;
  codigo_individual?: string;
  pode_gerenciar?: boolean;
  funcao?: string | null;
  crianca?: boolean;
  [chave: string]: unknown;
};
type ConviteRpc = {
  perfil_acesso?: string;
  funcao_cortejo?: string | null;
  pode_gerenciar?: boolean;
  convidados?: ConvidadoConviteRpc[];
  responsaveis?: Array<Record<string, unknown>>;
  [chave: string]: unknown;
};

type ConvidadoGrupoSeguro = ConvidadoConviteRpc & {
  convite_id: string;
  ordem?: number;
};

async function rpc(name: string, body: Record<string, unknown>) {
  if (!supabaseUrl || !supabaseKey) return null;
  return fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: supabaseKey, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
}
async function rpcAdmin(name:string,body:Record<string,unknown>){
  if(!supabaseUrl||!supabaseSecretKey)return null;
  return fetch(`${supabaseUrl}/rest/v1/rpc/${name}`,{
    method:"POST",
    headers:{apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`,"Content-Type":"application/json"},
    body:JSON.stringify(body),cache:"no-store",
  });
}

async function enriquecerFuncoesDoGrupo(
  convite: ConviteRpc,
  codigoAcesso: string,
): Promise<ConviteRpc> {
  if (!supabaseUrl || !supabaseSecretKey) return convite;
  const headers = {
    apikey: supabaseSecretKey,
    Authorization: `Bearer ${supabaseSecretKey}`,
  };
  const codigo = codigoAcesso.trim().toUpperCase();
  const pessoaResponse = await fetch(
    `${supabaseUrl}/rest/v1/convidados?codigo_individual=eq.${encodeURIComponent(codigo)}&select=id,convite_id,nome,codigo_individual,pode_gerenciar,funcao,crianca&limit=1`,
    { headers, cache: "no-store" },
  ).catch(() => null);
  if (!pessoaResponse?.ok) return convite;
  const pessoa = (await pessoaResponse.json() as ConvidadoGrupoSeguro[])[0];
  if (!pessoa?.convite_id) return convite;

  const grupoResponse = await fetch(
    `${supabaseUrl}/rest/v1/convidados?convite_id=eq.${encodeURIComponent(pessoa.convite_id)}&select=id,convite_id,nome,codigo_individual,pode_gerenciar,funcao,crianca,ordem&order=ordem.asc,nome.asc`,
    { headers, cache: "no-store" },
  ).catch(() => null);
  if (!grupoResponse?.ok) return convite;
  const grupo = await grupoResponse.json() as ConvidadoGrupoSeguro[];
  const dadosPorId = new Map(grupo.map((convidado) => [convidado.id, convidado]));
  const convidadosAtuais = Array.isArray(convite.convidados)
    ? convite.convidados
    : [];
  const convidados = convidadosAtuais.length
    ? convidadosAtuais.map((convidado) => ({
        ...convidado,
        ...(dadosPorId.get(convidado.id) ?? {}),
      }))
    : grupo;

  return {
    ...convite,
    pode_gerenciar: Boolean(pessoa.pode_gerenciar),
    convidados,
  };
}
async function sessaoAdministrativa(request:NextRequest){
  const token=request.cookies.get("sessao_noivos")?.value;
  if(!token)return null;
  const response=await rpc("dashboard_noivos",{p_token_hash:tokenHash(token)});
  if(!response?.ok)return null;
  const painel=await response.json() as PainelAdministrativo|null;
  return painel?.perfil==="admin"?painel:null;
}
async function registrarAuditoria(painel:PainelAdministrativo|null,acao:string,entidade:string,detalhes:Record<string,unknown>={}){
  if(!supabaseUrl||!supabaseSecretKey)return;
  await fetch(`${supabaseUrl}/rest/v1/auditoria_administrativa`,{method:"POST",headers:{apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`,"Content-Type":"application/json"},body:JSON.stringify({ator:painel?.conta?.nome||painel?.conta?.usuario||"Administração",perfil:painel?.perfil||"admin",acao,entidade,detalhes}),cache:"no-store"}).catch(()=>null);
}
async function mercadoPagoDisponivel(){
  if(!supabaseUrl||!supabaseSecretKey)return false;
  const r=await fetch(`${supabaseUrl}/rest/v1/integracoes_pagamento?id=eq.1&ativa=eq.true&select=id`,{headers:{apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`},cache:"no-store"});
  return r.ok&&((await r.json()) as unknown[]).length>0;
}
async function resolverConviteUnitario(codigoAcesso:string){
  if(!supabaseUrl||!supabaseSecretKey)return null;
  const codigo=codigoAcesso.trim().toUpperCase();
  const h={apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`};
  const conviteResponse=await fetch(
    `${supabaseUrl}/rest/v1/convites?codigo=eq.${encodeURIComponent(codigo)}&ativo=eq.true&select=id&limit=1`,
    {headers:h,cache:"no-store"},
  ).catch(()=>null);
  if(!conviteResponse?.ok)return null;
  const convite=(await conviteResponse.json() as Array<{id:string}>)[0];
  if(!convite?.id)return null;
  const convidadosResponse=await fetch(
    `${supabaseUrl}/rest/v1/convidados?convite_id=eq.${encodeURIComponent(convite.id)}&select=codigo_individual&order=ordem.asc&limit=2`,
    {headers:h,cache:"no-store"},
  ).catch(()=>null);
  if(!convidadosResponse?.ok)return null;
  const convidados=await convidadosResponse.json() as Array<{codigo_individual?:string}>;
  const codigoIndividual=String(convidados[0]?.codigo_individual??"").trim().toUpperCase();
  return convidados.length===1&&/^[A-Z0-9]{6}$/.test(codigoIndividual)
    ?codigoIndividual:null;
}
const tokenHash=(token:string)=>createHash("sha256").update(token).digest("hex");
async function criarHashSenha(senha:string){
  const salt = new Uint8Array(randomBytes(16));
  const hash = argon2id(senha, salt, ARGON2_OPTIONS);
  const saltBase64 = Buffer.from(salt).toString("base64").replace(/=+$/u, "");
  const hashBase64 = Buffer.from(hash).toString("base64").replace(/=+$/u, "");
  return `$argon2id$v=19$m=${ARGON2_OPTIONS.m},t=${ARGON2_OPTIONS.t},p=${ARGON2_OPTIONS.p}$${saltBase64}$${hashBase64}`;
}
async function verificarHashSenha(senha:string,phc:string){
  const partes = phc.match(/^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/u);
  if(!partes)return false;
  const [,memoria,iteracoes,paralelismo,saltBase64,hashBase64]=partes;
  const m=Number(memoria),t=Number(iteracoes),p=Number(paralelismo);
  if(!Number.isInteger(m)||m<8||m>65536||!Number.isInteger(t)||t<1||t>10||!Number.isInteger(p)||p<1||p>4)return false;
  const salt=new Uint8Array(Buffer.from(saltBase64,"base64"));
  const esperado=Buffer.from(hashBase64,"base64");
  const calculado=Buffer.from(argon2id(senha,salt,{m,t,p,dkLen:esperado.length}));
  return esperado.length===calculado.length&&timingSafeEqual(esperado,calculado);
}

function sanitizarFuncoesDoConvite(
  convite: ConviteRpc,
  codigoAcesso: string,
): ConviteRpc {
  if (["noivos", "assessoria", "admin"].includes(convite.perfil_acesso ?? ""))
    return convite;

  const convidados = Array.isArray(convite.convidados)
    ? convite.convidados
    : [];
  const codigo = codigoAcesso.trim().toUpperCase();
  const pessoa = convidados.find(
    (convidado) =>
      String(convidado.codigo_individual ?? "").trim().toUpperCase() === codigo,
  );
  const podeGerenciarCriancas = Boolean(
    pessoa &&
      (pessoa.pode_gerenciar || convite.pode_gerenciar) &&
      !ehCriancaDoCortejo({
        funcao: pessoa.funcao ?? null,
        crianca: Boolean(pessoa.crianca),
      }),
  );
  const idsComFuncaoLiberada = new Set<string>();
  if (pessoa?.id) idsComFuncaoLiberada.add(pessoa.id);
  if (podeGerenciarCriancas) {
    convidados.forEach((convidado) => {
      if (
        ehCriancaDoCortejo({
          funcao: convidado.funcao ?? null,
          crianca: Boolean(convidado.crianca),
        }) &&
        String(convidado.funcao ?? "").trim()
      )
        idsComFuncaoLiberada.add(convidado.id);
    });
  }

  const podeVerCodigosDoGrupo = Boolean(
    pessoa && (pessoa.pode_gerenciar || convite.pode_gerenciar),
  );
  const convidadosProtegidos = convidados.map((convidado) => ({
    ...convidado,
    funcao: idsComFuncaoLiberada.has(convidado.id)
      ? convidado.funcao ?? null
      : null,
    codigo_individual:
      convidado.id === pessoa?.id || podeVerCodigosDoGrupo
        ? convidado.codigo_individual
        : "PROTEGIDO",
  }));
  const responsaveisProtegidos = Array.isArray(convite.responsaveis)
    ? convite.responsaveis.map((responsavel) => ({
        ...responsavel,
        funcao: responsavel.id === pessoa?.id ? responsavel.funcao ?? null : null,
      }))
    : [];

  return {
    ...convite,
    funcao_cortejo: pessoa?.funcao ?? null,
    manuais: [],
    pode_gerenciar: podeVerCodigosDoGrupo,
    convidados: convidadosProtegidos,
    responsaveis: responsaveisProtegidos,
  };
}

export async function GET() {
  const response=await rpc("evento_publico",{});
  if(!response?.ok)return NextResponse.json({evento:EVENTO_PADRAO});
  const evento=await response.json();
  return NextResponse.json({evento:evento??EVENTO_PADRAO});
}

export async function POST(request: NextRequest) {
  const data = await request.json() as {
    action?: string; codigo?: string;
    usuario?: string;
    respostas?: Array<{ convidado_id: string; status: "sim" | "nao" }>;
    itens?:Array<{presente_id:string;quantidade:number}>;
    mensagem?: string;
    senha?:string;
    senha_atual?:string;
    nova_senha?:string;
    acao?:string;
    dados?:Record<string,unknown>;
    linhas?:Array<{
      nome:string;
      grupo?:string;
      funcao?:string;
      origem?:string;
      categoria?:string;
      valor?:number;
      links_fotos?:unknown[];
      descricao?:string;
      quantidade?:number|null;
      permitir_duplicado?:boolean;
    }>;
    nome?:string;
    solicitante?:string;
    idade?:number;
    chave_inicial?:string;
  };
  if(data.action==="logout_conta"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(token)await rpcAdmin("encerrar_sessao_organizacao_backend",{p_token_hash:tokenHash(token)}).catch(()=>null);
    const response=NextResponse.json({success:true});
    response.cookies.set("sessao_noivos","",{httpOnly:true,secure:true,sameSite:"lax",path:"/",maxAge:0});
    return response;
  }
  const codigo = data.codigo?.trim().toUpperCase();
  const identificador = data.usuario?.trim().toLowerCase() || codigo;
  const acoesConta = new Set(["estado_conta","criar_senha_conta","login_conta"]);
  if (acoesConta.has(data.action ?? "") && (!identificador || !/^(?:[A-Z0-9]{6}|[a-z0-9._-]{3,40})$/.test(identificador)))
    return NextResponse.json({ error: "Usuário ou código inválido." }, { status: 400 });
  if (!acoesConta.has(data.action ?? "") && (!codigo || !/^[A-Z0-9]{6}$/.test(codigo)))
    return NextResponse.json({ error: "Código inválido." }, { status: 400 });

  if(data.action==="estado_conta"){
    const response=await rpc("estado_organizacao",{p_identificador:identificador});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível verificar o acesso."},{status:502});
    const estado=await response.json();
    if(!estado)return NextResponse.json({error:"Conta não encontrada."},{status:404});
    return NextResponse.json({estado});
  }
  if(data.action==="criar_senha_conta"){
    if(!data.senha||data.senha.length<8||data.senha.length>128)return NextResponse.json({error:"A senha deve ter pelo menos 8 caracteres."},{status:400});
    const contaResponse=await rpcAdmin("resolver_conta_backend",{p_identificador:identificador});
    if(!contaResponse?.ok)return NextResponse.json({error:"Serviço seguro indisponível."},{status:503});
    const conta=await contaResponse.json() as {principal?:boolean;senha_hash?:string|null}|null;
    if(!conta)return NextResponse.json({error:"Conta não encontrada."},{status:404});
    if(conta.principal&&!conta.senha_hash){
      const chaveEsperada=process.env.ADMIN_SETUP_KEY;
      const chaveRecebida=String(data.chave_inicial??"");
      if(!chaveEsperada)return NextResponse.json({error:"Configure ADMIN_SETUP_KEY antes do primeiro acesso administrativo."},{status:503});
      const a=Buffer.from(chaveEsperada),b=Buffer.from(chaveRecebida);
      if(a.length!==b.length||!timingSafeEqual(a,b))return NextResponse.json({error:"Chave inicial inválida."},{status:403});
    }
    let hash:string;try{hash=await criarHashSenha(data.senha)}catch{return NextResponse.json({error:"Não foi possível processar a senha."},{status:500})}
    const response=await rpcAdmin("salvar_hash_conta_backend",{p_identificador:identificador,p_hash:hash});
    if(!response?.ok)return NextResponse.json({error:"Serviço seguro indisponível."},{status:503});
    const resultado=await response.json();
    if(resultado!=="criada")return NextResponse.json({error:resultado==="ja_criada"?"A senha já existe. Entre com a senha atual.":"Não foi possível criar a senha."},{status:409});
    return NextResponse.json({success:true});
  }
  if(data.action==="login_conta"){
    if(!data.senha)return NextResponse.json({error:"Informe a senha."},{status:400});
    const acessoResponse=await rpcAdmin("resolver_conta_backend",{p_identificador:identificador});
    if(!acessoResponse?.ok)return NextResponse.json({error:"Serviço seguro indisponível."},{status:503});
    const acesso=await acessoResponse.json() as {senha_hash:string|null;exige_troca_senha:boolean}|null;
    if(!acesso?.senha_hash)return NextResponse.json({error:"Crie uma senha no primeiro acesso."},{status:409});
    try{if(!await verificarHashSenha(data.senha,acesso.senha_hash))return NextResponse.json({error:"Senha incorreta."},{status:401})}
    catch{return NextResponse.json({error:"Não foi possível verificar a senha."},{status:500})}
    const token=randomBytes(32).toString("base64url");
    const response=await rpcAdmin("criar_sessao_organizacao_backend",{p_identificador:identificador,p_token_hash:tokenHash(token)});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Não foi possível iniciar a sessão."},{status:401});
    const result=NextResponse.json({success:true,exige_troca_senha:acesso.exige_troca_senha});
    result.cookies.set("sessao_noivos",token,{httpOnly:true,secure:true,sameSite:"lax",path:"/",maxAge:604800});
    return result;
  }

  if (data.action === "buscar") {
    const codigoIndividualUnitario=await resolverConviteUnitario(codigo as string);
    const codigoEfetivo=codigoIndividualUnitario??codigo;
    const response = await rpc("buscar_convite", { p_codigo: codigoEfetivo });
    if (!response) return NextResponse.json({ error: "Supabase não configurado." }, { status: 503 });
    if (!response.ok) return NextResponse.json({ error: "Não foi possível consultar o convite." }, { status: 502 });
    const conviteBruto = await response.json() as ConviteRpc | null;
    if (!conviteBruto) return NextResponse.json({ error: "Código não encontrado." }, { status: 404 });
    const conviteCompleto = await enriquecerFuncoesDoGrupo(
      conviteBruto,
      codigoEfetivo as string,
    );
    const convite = sanitizarFuncoesDoConvite(
      conviteCompleto,
      codigoEfetivo as string,
    );
    const giftsResponse=await rpc("listar_presentes",{});
    return NextResponse.json({
      convite,
      presentes:giftsResponse?.ok?await giftsResponse.json():[],
      mercado_pago_disponivel:await mercadoPagoDisponivel(),
      convite_unitario:Boolean(codigoIndividualUnitario),
      codigo_individual_destino:codigoIndividualUnitario,
    });
  }
  if(data.action==="confirmar_presentes"){
    if(!Array.isArray(data.itens)||data.itens.length===0)return NextResponse.json({error:"O carrinho está vazio."},{status:400});
    const itens=data.itens.slice(0,30).map(i=>({presente_id:i.presente_id,quantidade:Math.max(1,Math.min(20,Math.floor(Number(i.quantidade))))}));
    const response=await rpc("confirmar_presentes",{p_codigo:codigo,p_itens:itens});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Algum presente não tem mais a quantidade escolhida. Atualize o carrinho e tente novamente."},{status:409});
    const listResponse=await rpc("listar_presentes",{});
    return NextResponse.json({success:true,presentes:listResponse?.ok?await listResponse.json():[]});
  }
  if(data.action==="criar_senha"){
    if(!data.senha||data.senha.length<8||data.senha.length>128)return NextResponse.json({error:"A senha deve ter pelo menos 8 caracteres."},{status:400});
    let hash:string;
    try{hash=await criarHashSenha(data.senha)}
    catch{return NextResponse.json({error:"Não foi possível processar a senha com Argon2id."},{status:500})}
    const response=await rpcAdmin("salvar_hash_argon2_backend",{p_codigo:codigo,p_hash:hash});
    if(!response?.ok)return NextResponse.json({error:"O serviço seguro de autenticação não está configurado."},{status:503});
    const resultado=await response.json();
    if(resultado==="ja_criada")return NextResponse.json({error:"A senha deste acesso já foi criada. Use a opção de entrar."},{status:409});
    if(resultado==="sem_acesso")return NextResponse.json({error:"Este código não possui acesso administrativo."},{status:403});
    if(resultado!=="criada")return NextResponse.json({error:"Não foi possível criar a senha."},{status:400});
    return NextResponse.json({success:true});
  }
  if(data.action==="estado_acesso"){
    const response=await rpc("estado_acesso",{p_codigo:codigo});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível verificar o acesso."},{status:502});
    const estado=await response.json();
    if(!estado)return NextResponse.json({error:"Este código não possui acesso administrativo."},{status:404});
    return NextResponse.json({estado});
  }
  if(data.action==="login_noivos"){
    if(!data.senha)return NextResponse.json({error:"Informe a senha."},{status:400});
    const acessoResponse=await rpcAdmin("resolver_acesso_backend",{p_codigo:codigo});
    if(!acessoResponse?.ok)return NextResponse.json({error:"O serviço seguro de autenticação não está configurado."},{status:503});
    const acesso=await acessoResponse.json() as {senha_hash:string|null}|null;
    if(!acesso?.senha_hash||!acesso.senha_hash.startsWith("$argon2id$"))return NextResponse.json({error:"Crie uma nova senha Argon2id no primeiro acesso."},{status:409});
    try{if(!await verificarHashSenha(data.senha,acesso.senha_hash))return NextResponse.json({error:"Senha incorreta."},{status:401})}
    catch{return NextResponse.json({error:"Não foi possível verificar a senha Argon2id."},{status:500})}
    const token=randomBytes(32).toString("base64url");
    const response=await rpcAdmin("criar_sessao_backend",{p_codigo:codigo,p_token_hash:tokenHash(token)});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Senha incorreta."},{status:401});
    const result=NextResponse.json({success:true});result.cookies.set("sessao_noivos",token,{httpOnly:true,secure:true,sameSite:"lax",path:"/",maxAge:604800});return result;
  }
  if(data.action==="dashboard"){
    const token=request.cookies.get("sessao_noivos")?.value;if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const response=await rpc("dashboard_noivos",{p_token_hash:tokenHash(token)});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível carregar o painel."},{status:502});
    const dashboard=await response.json();if(!dashboard)return NextResponse.json({error:"Sessão expirada."},{status:401});
    if(dashboard.perfil!=="assessoria"){
      const [configResponse,categoriasResponse]=await Promise.all([
        rpc("configuracoes_convites_dashboard",{p_token_hash:tokenHash(token)}),
        rpc("listar_categorias_presentes_dashboard",{p_token_hash:tokenHash(token)}),
      ]);
      if(configResponse?.ok)dashboard.configuracoes=await configResponse.json();
      if(categoriasResponse?.ok)dashboard.categorias_presentes=await categoriasResponse.json();
    }
    return NextResponse.json({dashboard});
  }
  if(data.action==="controles_administrativos"){
    const painel=await sessaoAdministrativa(request);if(!painel)return NextResponse.json({error:"Acesso administrativo necessário."},{status:403});
    if(!supabaseUrl||!supabaseSecretKey)return NextResponse.json({error:"Banco não configurado."},{status:503});
    const h={apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`};
    const [auditoria,falhas,reservas,presentes]=await Promise.all([
      fetch(`${supabaseUrl}/rest/v1/auditoria_administrativa?select=*&order=criado_em.desc&limit=200`,{headers:h,cache:"no-store"}),
      fetch(`${supabaseUrl}/rest/v1/falhas_webhook_pagamento?select=*&order=criado_em.desc&limit=100`,{headers:h,cache:"no-store"}),
      fetch(`${supabaseUrl}/rest/v1/reservas_presentes?select=id,convite_id,presente_id,quantidade,status,criado_em,atualizado_em,meio,preferencia_id,pagamento_id,pagamento_status,external_reference,aprovado_em,pagador_nome,pagador_email,meio_pagamento_detalhe,valor_transacao,reembolso_id,reembolsado_em,doador_chave,cpf_consentimento_em,cpf_politica_versao,mensagem,tentativa_pagamento_ate,conciliacao_pagamento_ate,tipo_pagamento,boleto_vencimento`,{headers:h,cache:"no-store"}),
      fetch(`${supabaseUrl}/rest/v1/presentes?select=*`,{headers:h,cache:"no-store"}),
    ]);
    return NextResponse.json({auditoria:auditoria.ok?await auditoria.json():[],falhas_webhook:falhas.ok?await falhas.json():[],reservas:reservas.ok?await reservas.json():[],presentes:presentes.ok?await presentes.json():[]});
  }
  if(data.action==="anonimizar_cpfs"){
    const painel=await sessaoAdministrativa(request);if(!painel)return NextResponse.json({error:"Acesso administrativo necessário."},{status:403});
    if(!supabaseUrl||!supabaseSecretKey)return NextResponse.json({error:"Banco não configurado."},{status:503});
    const response=await fetch(`${supabaseUrl}/rest/v1/reservas_presentes?cpf_cifrado=not.is.null`,{method:"PATCH",headers:{apikey:supabaseSecretKey,Authorization:`Bearer ${supabaseSecretKey}`,"Content-Type":"application/json",Prefer:"return=representation"},body:JSON.stringify({cpf_cifrado:null,cpf_consentimento_em:null,cpf_politica_versao:null}),cache:"no-store"});
    if(!response.ok)return NextResponse.json({error:"Não foi possível anonimizar os CPFs."},{status:502});
    const alterados=(await response.json() as unknown[]).length;await registrarAuditoria(painel,"anonimizar_cpfs","reservas_presentes",{registros:alterados});
    return NextResponse.json({success:true,alterados});
  }
  if(data.action==="resolver_falha_webhook"){
    const painel=await sessaoAdministrativa(request);if(!painel)return NextResponse.json({error:"Acesso administrativo necessário."},{status:403});
    const id=String(data.dados?.id||"");if(!/^[0-9a-f-]{36}$/i.test(id))return NextResponse.json({error:"Alerta inválido."},{status:400});
    const response=await fetch(`${supabaseUrl}/rest/v1/falhas_webhook_pagamento?id=eq.${id}`,{method:"PATCH",headers:{apikey:supabaseSecretKey!,Authorization:`Bearer ${supabaseSecretKey}`,"Content-Type":"application/json"},body:JSON.stringify({resolvida:true,resolvida_em:new Date().toISOString()}),cache:"no-store"});
    if(!response.ok)return NextResponse.json({error:"Não foi possível atualizar o alerta."},{status:502});await registrarAuditoria(painel,"resolver_alerta_webhook","falhas_webhook_pagamento",{id});
    return NextResponse.json({success:true});
  }
  if(data.action==="configuracoes_dashboard"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const [configResponse,categoriasResponse]=await Promise.all([
      rpc("configuracoes_convites_dashboard",{p_token_hash:tokenHash(token)}),
      rpc("listar_categorias_presentes_dashboard",{p_token_hash:tokenHash(token)}),
    ]);
    if(!configResponse?.ok||!categoriasResponse?.ok)return NextResponse.json({error:"Execute a migração das configurações gerais."},{status:502});
    return NextResponse.json({configuracoes:await configResponse.json(),categorias:await categoriasResponse.json()});
  }
  if(data.action==="administrar_configuracoes"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados)return NextResponse.json({error:"Dados incompletos."},{status:400});
    const response=await rpc("administrar_configuracoes_convites",{p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:data.dados});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível salvar. Execute a migração mais recente."},{status:502});
    if((await response.json())!==true)return NextResponse.json({error:"Acesso não permitido ou dados inválidos."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="listar_presentes_dashboard"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const acesso=await rpc("dashboard_noivos",{p_token_hash:tokenHash(token)});
    const painel=acesso?.ok?await acesso.json() as PainelAdministrativo|null:null;
    if(!painel)return NextResponse.json({error:"Sessão expirada."},{status:401});
    if(painel.perfil==="assessoria")return NextResponse.json({error:"Acesso não permitido para a assessoria."},{status:403});
    const response=await rpc("listar_presentes",{});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível carregar os presentes."},{status:502});
    return NextResponse.json({presentes:await response.json()});
  }
  if(data.action==="administrar_imagens_presente"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const presenteId=String(data.dados?.presente_id??"");
    const imagensBrutas=Array.isArray(data.dados?.imagens)?data.dados.imagens:[];
    const imagens=imagensBrutas.map(v=>String(v).trim()).filter(Boolean);
    if(!/^[0-9a-f-]{36}$/i.test(presenteId)||imagens.length>10)
      return NextResponse.json({error:"Dados de imagem inválidos."},{status:400});
    try{
      if(imagens.some(url=>!/^https?:\/\//i.test(url)||url.length>1000))throw new Error();
    }catch{return NextResponse.json({error:"Use URLs completas iniciadas por http:// ou https://."},{status:400})}
    const response=await rpc("administrar_imagens_presente",{p_token_hash:tokenHash(token),p_presente_id:presenteId,p_imagens:imagens});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Acesso não permitido ou presente inválido."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="administrar_presente"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados)return NextResponse.json({error:"Dados incompletos."},{status:400});
    let dadosPresente:Record<string,unknown>;
    if(data.acao==="criar"||data.acao==="editar"){
      const id=data.acao==="editar"?String(data.dados.id??""):null;
      const nome=String(data.dados.nome??"").trim().slice(0,150);
      const descricao=String(data.dados.descricao??"").trim().slice(0,1000);
      const categoriaId=data.dados.categoria_id?String(data.dados.categoria_id):null;
      const precoCentavos=Number(data.dados.preco_centavos);
      const quantidadeBruta=data.dados.quantidade_total;
      const quantidadeTotal=quantidadeBruta===null||quantidadeBruta===undefined||String(quantidadeBruta).trim()===""
        ?null:Number(quantidadeBruta);
      const imagensBrutas=Array.isArray(data.dados.imagens)?data.dados.imagens:[];
      const imagens=imagensBrutas.map((url)=>String(url).trim().slice(0,1000)).filter(Boolean);
      if((id!==null&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))
        ||nome.length<2||!Number.isInteger(precoCentavos)||precoCentavos<0||precoCentavos>100000000
        ||(quantidadeTotal!==null&&(!Number.isInteger(quantidadeTotal)||quantidadeTotal<1||quantidadeTotal>10000))
        ||(categoriaId!==null&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(categoriaId))
        ||imagens.length>10||imagens.some((url)=>!/^https?:\/\//i.test(url)))
        return NextResponse.json({error:"Revise o nome, valor, quantidade, categoria e links das imagens."},{status:400});
      dadosPresente={
        ...(id?{id}:{}),
        nome,descricao,categoria_id:categoriaId,preco_centavos:precoCentavos,
        quantidade_total:quantidadeTotal,imagens,
        permitir_duplicado:data.dados.permitir_duplicado===true,
      };
    }else if(data.acao==="excluir"){
      const id=String(data.dados.id??"");
      if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))
        return NextResponse.json({error:"Presente inválido."},{status:400});
      dadosPresente={id};
    }else{
      return NextResponse.json({error:"Ação inválida."},{status:400});
    }
    const response=await rpc("administrar_presente_dashboard",{
      p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:dadosPresente,
    });
    if(!response?.ok)return NextResponse.json({error:"Não foi possível atualizar a lista. Execute a migração mais recente no Supabase."},{status:502});
    if((await response.json())!==true)return NextResponse.json({error:"Acesso não permitido, presente duplicado ou dados inválidos."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="administrar_entrega_presente"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const reservaId=String(data.dados?.reserva_id??"");
    const entregue=data.dados?.entregue;
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(reservaId)||typeof entregue!=="boolean")
      return NextResponse.json({error:"Assinatura ou status de entrega inválido."},{status:400});
    const response=await rpc("administrar_entrega_presente",{
      p_token_hash:tokenHash(token),p_reserva_id:reservaId,p_entregue:entregue,
    });
    if(!response?.ok)return NextResponse.json({error:"Não foi possível atualizar a entrega. Execute a migração mais recente no Supabase."},{status:502});
    if((await response.json())!==true)return NextResponse.json({error:"Acesso não permitido ou assinatura física inválida."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="importar_convidados"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!Array.isArray(data.linhas)||data.linhas.length<1||data.linhas.length>1000)
      return NextResponse.json({error:"A planilha deve conter de 1 a 1.000 convidados."},{status:400});
    const linhas=data.linhas.map(item=>({
      nome:String(item.nome??"").trim().slice(0,150),
      grupo:String(item.grupo??"").trim().slice(0,150),
      funcao:String(item.funcao??"").trim().slice(0,80),
      origem:["noivo","noiva","ambos","nao_classificado"].includes(String(item.origem))?String(item.origem):"nao_classificado",
    })).filter(item=>item.nome.length>=2);
    if(!linhas.length)return NextResponse.json({error:"Nenhum nome válido foi encontrado."},{status:400});
    const response=await rpc("importar_convidados_automatico",{p_token_hash:tokenHash(token),p_linhas:linhas});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível importar a planilha."},{status:502});
    const importados=Number(await response.json());
    if(!Number.isInteger(importados)||importados<0)return NextResponse.json({error:"Sessão expirada, acesso não permitido ou planilha inválida."},{status:403});
    return NextResponse.json({success:true,importados});
  }
  if(data.action==="importar_presentes"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!Array.isArray(data.linhas)||data.linhas.length<1||data.linhas.length>1000)
      return NextResponse.json({error:"A planilha deve conter de 1 a 1.000 presentes."},{status:400});
    const linhas=data.linhas.map(item=>({
      nome:String(item.nome??"").trim().slice(0,150),
      categoria:String(item.categoria??"").trim().slice(0,80),
      valor:Number(item.valor??0),
      links_fotos:Array.isArray(item.links_fotos)?item.links_fotos.map((v:unknown)=>String(v).trim().slice(0,1000)).filter(Boolean).slice(0,10):[],
      descricao:String(item.descricao??"").trim().slice(0,1000),
      quantidade:item.quantidade===null||item.quantidade===undefined||String(item.quantidade).trim()===""
        ?null:Math.max(1,Math.min(10000,Math.trunc(Number(item.quantidade)||1))),
      permitir_duplicado:item.permitir_duplicado===true,
    })).filter(item=>item.nome.length>=2&&Number.isFinite(item.valor)&&item.valor>=0&&item.links_fotos.every((url:string)=>/^https?:\/\//i.test(url)));
    if(!linhas.length)return NextResponse.json({error:"Nenhum presente válido foi encontrado."},{status:400});
    const response=await rpc("importar_presentes_automatico",{p_token_hash:tokenHash(token),p_linhas:linhas});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível importar. Execute a migração mais recente no Supabase."},{status:502});
    const importados=Number(await response.json());
    if(!Number.isInteger(importados)||importados<0)return NextResponse.json({error:"Sessão expirada, acesso não permitido ou planilha inválida."},{status:403});
    return NextResponse.json({success:true,importados});
  }
  if(data.action==="administrar"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados)return NextResponse.json({error:"Dados incompletos."},{status:400});
    const response=["adicionar_com_codigo","editar_com_codigo"].includes(data.acao)
      ?await rpc("administrar_convidado_com_codigo",{p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:data.dados})
      :data.acao==="presenca"
      ?await rpc("administrar_status_convite",{p_token_hash:tokenHash(token),p_convidado_id:data.dados.id,p_status:data.dados.status})
      :data.acao==="configurar_idade_crianca"
        ?await rpc("configurar_idade_crianca",{p_token_hash:tokenHash(token),p_idade:data.dados.idade})
        :await rpc("administrar_convidados",{p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:data.dados});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível realizar a alteração."},{status:502});
    if((await response.json())!==true)return NextResponse.json({error:["adicionar_com_codigo","editar_com_codigo"].includes(data.acao)?"Esse código já está em uso ou os dados são inválidos.":"Sessão expirada ou dados inválidos."},{status:403});
    if(data.acao==="editar"&&data.dados.id&&typeof data.dados.crianca==="boolean"){
      const classificacao=await rpc("definir_convidado_crianca",{p_token_hash:tokenHash(token),p_convidado_id:data.dados.id,p_crianca:data.dados.crianca});
      if(!classificacao?.ok||(await classificacao.json())!==true)return NextResponse.json({error:"Os dados foram salvos, mas não foi possível atualizar a classificação de criança."},{status:502});
    }
    if(["adicionar","editar","editar_com_codigo"].includes(data.acao)&&data.dados.id&&typeof data.dados.origem==="string"){
      const origem=await rpc("administrar_origem_convidado",{p_token_hash:tokenHash(token),p_convidado_id:data.dados.id,p_origem:data.dados.origem});
      if(!origem?.ok||(await origem.json())!==true)return NextResponse.json({error:"Os dados foram salvos, mas não foi possível atualizar a classificação do convidado."},{status:502});
    }
    return NextResponse.json({success:true});
  }
  if(data.action==="administrar_grupos"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados)return NextResponse.json({error:"Dados incompletos."},{status:400});
    const response=await rpc("administrar_grupos",{p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:data.dados});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível salvar o grupo."},{status:502});
    if((await response.json())!==true)return NextResponse.json({error:"Código já utilizado, dados inválidos ou acesso não permitido."},{status:403});
    if(Number.isInteger(Number(data.dados.criancas_adicionais_limite))){
      const extras=await rpc("configurar_criancas_grupo",{p_token_hash:tokenHash(token),p_codigo:data.dados.codigo,p_limite:Number(data.dados.criancas_adicionais_limite)});
      if(!extras?.ok||(await extras.json())!==true)return NextResponse.json({error:"O grupo foi salvo, mas não foi possível atualizar o limite de crianças."},{status:502});
    }
    return NextResponse.json({success:true});
  }
  if(data.action==="alterar_propria_senha"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.senha_atual||!data.nova_senha||data.nova_senha.length<8||data.nova_senha.length>128)
      return NextResponse.json({error:"Informe a senha atual e uma nova senha com pelo menos 8 caracteres."},{status:400});
    const contaResponse=await rpcAdmin("resolver_conta_por_sessao_backend",{p_token_hash:tokenHash(token)});
    if(!contaResponse?.ok)return NextResponse.json({error:"Atualize a migração do banco antes de alterar senhas."},{status:503});
    const conta=await contaResponse.json() as {senha_hash:string|null}|null;
    if(!conta?.senha_hash)return NextResponse.json({error:"Conta não encontrada."},{status:404});
    if(!await verificarHashSenha(data.senha_atual,conta.senha_hash))return NextResponse.json({error:"A senha atual está incorreta."},{status:401});
    const novoHash=await criarHashSenha(data.nova_senha);
    const response=await rpcAdmin("alterar_senha_organizacao_backend",{p_token_hash:tokenHash(token),p_novo_hash:novoHash});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Não foi possível alterar a senha."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="administrar_organizacao"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados)return NextResponse.json({error:"Dados incompletos."},{status:400});
    let hash:string|null=null;
    let senhaTemporaria:string|undefined;
    if(data.acao==="criar"||data.acao==="resetar_senha"){
      senhaTemporaria=String(randomInt(10000000,100000000));
      hash=await criarHashSenha(senhaTemporaria);
    }else if(data.acao==="definir_senha"){
      const nova=String(data.dados.senha??"");
      if(nova.length<8||nova.length>128)return NextResponse.json({error:"A nova senha deve ter pelo menos 8 caracteres."},{status:400});
      hash=await criarHashSenha(nova);
    }
    const response=await rpcAdmin("administrar_organizacao_backend",{p_token_hash:tokenHash(token),p_acao:data.acao,p_dados:data.dados,p_hash:hash});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível administrar a organização."},{status:502});
    const resultado=await response.json() as {ok:boolean;codigo?:string;motivo?:string};
    if(!resultado.ok){
      const mensagens:Record<string,string>={
        codigo_invalido:"O código deve ter exatamente 6 letras ou números.",
        codigo_indisponivel:"Esse código já está sendo usado por um convidado, grupo ou integrante da organização.",
        usuario_indisponivel:"Esse usuário já está em uso.",
        dados_invalidos:"Confira o nome, o usuário, a função e o código informados.",
      };
      return NextResponse.json({error:mensagens[resultado.motivo??""]??"Acesso não permitido ou dados inválidos."},{status:403});
    }
    return NextResponse.json({success:true,codigo:resultado.codigo,senha_temporaria:senhaTemporaria});
  }
  if(data.action==="administrar_expiracao"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    if(!data.acao||!data.dados?.convite_id)return NextResponse.json({error:"Dados incompletos."},{status:400});
    const response=await rpc("administrar_expiracao",{p_token_hash:tokenHash(token),p_convite_id:data.dados.convite_id,p_acao:data.acao,p_data:data.dados.data??null});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Não foi possível alterar a validade."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="administrar_evento"){
    const token=request.cookies.get("sessao_noivos")?.value;
    if(!token)return NextResponse.json({error:"Faça login novamente."},{status:401});
    const evento=data.dados??{};
    const response=await rpc("administrar_configuracao_evento",{p_token_hash:tokenHash(token),p_dados:evento});
    if(!response?.ok||(await response.json())!==true)return NextResponse.json({error:"Acesso não permitido ou dados do evento inválidos."},{status:403});
    return NextResponse.json({success:true});
  }
  if(data.action==="adicionar_crianca"){
    const idade=Number(data.idade);
    if(!Number.isInteger(idade)||idade<0||idade>120||String(data.nome??"").trim().length<2||String(data.solicitante??"").trim().length<2)
      return NextResponse.json({error:"Informe nome completo, idade e responsável."},{status:400});
    const response=await rpc("adicionar_crianca_grupo",{p_codigo:codigo,p_nome:String(data.nome).trim().slice(0,150),p_idade:idade,p_solicitante:String(data.solicitante).trim().slice(0,150)});
    if(!response?.ok)return NextResponse.json({error:"Não foi possível adicionar a pessoa."},{status:502});
    const resultado=await response.json() as {ok:boolean;motivo?:string;restantes?:number;crianca?:boolean};
    if(!resultado.ok){
      const mensagens:Record<string,string>={
        adulto_notificado:"Esta pessoa tem 18 anos ou mais. A solicitação foi enviada aos noivos e à organização para inclusão como adulto.",
        limite_atingido:"O limite de crianças adicionais deste grupo foi atingido.",
        sem_permissao:"Somente um responsável autorizado pelo grupo pode adicionar crianças."
      };
      return NextResponse.json({error:mensagens[resultado.motivo??""]||"Não foi possível adicionar a pessoa.",notificado:resultado.motivo==="adulto_notificado"},{status:409});
    }
    return NextResponse.json({success:true,...resultado});
  }

  if (data.action === "confirmar") {
    if (!Array.isArray(data.respostas) || data.respostas.length === 0)
      return NextResponse.json({ error: "Informe as respostas." }, { status: 400 });
    const response = await rpc("salvar_confirmacao", {
      p_codigo: codigo, p_respostas: data.respostas,
      p_mensagem: data.mensagem?.slice(0, 1000) ?? null,
    });
    if (!response || !response.ok || (await response.json()) !== true)
      return NextResponse.json({ error: "Não foi possível salvar a confirmação." }, { status: 502 });
    return NextResponse.json({ success: true });
  }
  return NextResponse.json({ error: "Ação inválida." }, { status: 400 });
}
