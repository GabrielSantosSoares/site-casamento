"use client";
import {FormEvent,useEffect,useState} from "react";
import {Dashboard,DashboardNoivos} from "../../componentes/DashboardNoivos";

const USUARIO="admin";
const CODIGO_API="ADMINX";

export default function Administracao(){
 const [primeiro,setPrimeiro]=useState<boolean|null>(null),[senha,setSenha]=useState(""),[confirmacao,setConfirmacao]=useState(""),[chaveInicial,setChaveInicial]=useState("");
 const [aviso,setAviso]=useState(""),[carregando,setCarregando]=useState(true),[dashboard,setDashboard]=useState<Dashboard|null>(null);
 useEffect(()=>{(async()=>{try{const r=await fetch("/api/convite",{method:"POST",headers:{"Content-Type":"application/json"},cache:"no-store",body:JSON.stringify({action:"estado_conta",usuario:USUARIO})});const d=await r.json();if(!r.ok)throw new Error(d.error);setPrimeiro(!d.estado.senha_criada)}catch{setPrimeiro(true);setAviso("")}finally{setCarregando(false)}})()},[]);
 async function enviar(e:FormEvent){
  e.preventDefault();setAviso("");
  if(primeiro&&senha!==confirmacao){setAviso("As senhas digitadas não são iguais.");return}
  setCarregando(true);
  try{
   if(primeiro){
    const r=await fetch("/api/convite",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"criar_senha_conta",usuario:USUARIO,senha,chave_inicial:chaveInicial})});
    const d=await r.json();if(!r.ok){if(r.status===409){setPrimeiro(false);setConfirmacao("");throw new Error("A senha já existe. Digite-a para entrar.")}throw new Error(d.error||"Não foi possível criar a senha.");}
   }
   const r=await fetch("/api/convite",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"login_conta",usuario:USUARIO,senha})});
   const d=await r.json();if(!r.ok)throw new Error(d.error||"Senha incorreta.");
   const rd=await fetch("/api/convite",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"dashboard",codigo:CODIGO_API})});
   const dd=await rd.json();if(!rd.ok)throw new Error(dd.error||"Não foi possível carregar o painel.");
   setDashboard(dd.dashboard);
  }catch(error){setAviso(error instanceof Error?error.message:"Não foi possível acessar.");}
  finally{setCarregando(false)}
 }
 async function sair(){
  await fetch("/api/convite",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"logout_conta"})}).catch(()=>undefined);
  window.location.assign("/");
 }
 if(dashboard)return <main className="guest-app admin-route"><header className="guest-header"><span className="brand"><span className="monogram"><img src="/monograma-ga.png" alt=""/></span><span>Administração</span></span><button className="exit" onClick={()=>void sair()}>Sair</button></header><section className="guest-content"><DashboardNoivos dados={dashboard} codigo={CODIGO_API}/></section></main>;
 return <main className="admin-route"><section className="guest-content"><div className="panel couple-login"><p className="eyebrow">Administração</p><h1>{primeiro===null?"Verificando acesso":primeiro?"Crie a senha do administrador":"Entrar no dashboard"}</h1><p>O primeiro acesso é obrigatoriamente pelo usuário principal <b>admin</b>.</p>{primeiro!==null&&<form onSubmit={enviar}><label htmlFor="admin-user">Usuário</label><input id="admin-user" value={USUARIO} readOnly/>{primeiro&&<><label htmlFor="admin-setup-key">Chave inicial segura</label><input id="admin-setup-key" type="password" value={chaveInicial} onChange={e=>setChaveInicial(e.target.value)} required autoComplete="off"/><small>Use o valor configurado em ADMIN_SETUP_KEY no ambiente do site.</small></>}<label htmlFor="admin-password">Senha</label><input id="admin-password" type="password" minLength={8} maxLength={128} value={senha} onChange={e=>setSenha(e.target.value)} required autoComplete={primeiro?"new-password":"current-password"}/>{primeiro&&<><label htmlFor="admin-confirm">Confirmar senha</label><input id="admin-confirm" type="password" minLength={8} maxLength={128} value={confirmacao} onChange={e=>setConfirmacao(e.target.value)} required autoComplete="new-password"/></>}{aviso&&<p className="error">{aviso}</p>}<button className="primary" disabled={carregando}>{carregando?"Acessando...":primeiro?"Criar senha e entrar":"Entrar"}</button></form>}</div></section></main>
}
