import { NextRequest, NextResponse } from "next/server";
import { createDecipheriv, createHash } from "node:crypto";
const url=process.env.SUPABASE_URL,key=process.env.SUPABASE_SECRET_KEY,enc=process.env.MP_CREDENTIAL_ENCRYPTION_KEY;
const headers=()=>({apikey:key!,Authorization:`Bearer ${key}`,"Content-Type":"application/json"});
async function registrarFalha(pagamento_id:string|null,etapa:string,mensagem:string){
 if(!url||!key)return;
 await fetch(`${url}/rest/v1/falhas_webhook_pagamento`,{method:"POST",headers:headers(),body:JSON.stringify({pagamento_id,etapa,mensagem:mensagem.slice(0,500)})}).catch(()=>null);
}
function decrypt(v:string){const [i,t,d]=v.split("."),k=createHash("sha256").update(enc!).digest(),x=createDecipheriv("aes-256-gcm",k,Buffer.from(i,"base64"));x.setAuthTag(Buffer.from(t,"base64"));return Buffer.concat([x.update(Buffer.from(d,"base64")),x.final()]).toString("utf8")}
export async function POST(request:NextRequest){
 try{const body=await request.json() as {type?:string;data?:{id?:string|number}};if(body.type!=="payment"||!body.data?.id)return NextResponse.json({ok:true});
  const cr=await fetch(`${url}/rest/v1/integracoes_pagamento?id=eq.1&ativa=eq.true&select=access_token_cifrado`,{headers:headers(),cache:"no-store"}),c=(await cr.json())[0];if(!c)return NextResponse.json({ok:true});
  const token=decrypt(c.access_token_cifrado),pr=await fetch(`https://api.mercadopago.com/v1/payments/${body.data.id}`,{headers:{Authorization:`Bearer ${token}`},cache:"no-store"});if(!pr.ok){await registrarFalha(String(body.data.id),"consulta_mercado_pago",`HTTP ${pr.status}`);return NextResponse.json({ok:true});}
  const p=await pr.json() as {id:number;status:string;external_reference?:string;transaction_amount?:number;payment_method_id?:string;payment_type_id?:string;date_of_expiration?:string;payer?:{email?:string;first_name?:string;last_name?:string}};if(!p.external_reference)return NextResponse.json({ok:true});
  const boleto=p.payment_type_id==="ticket"||p.payment_method_id==="bolbradesco"||p.payment_method_id==="pec";
  const status=p.status==="approved"?"confirmado":p.status==="refunded"?"reembolsado":boleto&&(p.status==="rejected"||p.status==="cancelled")?"cancelado":"pendente";
  const pagadorNome=[p.payer?.first_name,p.payer?.last_name].filter(Boolean).join(" ")||null;
  const atualizado=await fetch(`${url}/rest/v1/reservas_presentes?external_reference=eq.${encodeURIComponent(p.external_reference)}&meio=eq.mercado_pago`,{method:"PATCH",headers:headers(),body:JSON.stringify({status,pagamento_id:String(p.id),pagamento_status:p.status,pagador_nome:pagadorNome,pagador_email:p.payer?.email??null,meio_pagamento_detalhe:p.payment_method_id||p.payment_type_id||null,tipo_pagamento:p.payment_type_id??null,boleto_vencimento:boleto&&p.date_of_expiration?p.date_of_expiration:null,valor_transacao:p.transaction_amount??null,aprovado_em:p.status==="approved"?new Date().toISOString():null,reembolsado_em:p.status==="refunded"?new Date().toISOString():null,atualizado_em:new Date().toISOString()})});
  if(!atualizado.ok)await registrarFalha(String(p.id),"atualizacao_banco",`HTTP ${atualizado.status}`);
  return NextResponse.json({ok:true});
 }catch(erro){await registrarFalha(null,"processamento",erro instanceof Error?erro.message:"Erro inesperado");return NextResponse.json({ok:true});}
}
