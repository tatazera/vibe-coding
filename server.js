const express=require("express"),cors=require("cors"),fs=require("fs"),path=require("path"),crypto=require("crypto");
const app=express(),PORT=3000,TOKEN=process.env.BRIDGE_TOKEN||"",DATA="/data/entradas.json",STATE="/data/state.json";
app.use(cors());app.use(express.json({limit:"5mb"}));
function ler(){try{if(fs.existsSync(DATA))return JSON.parse(fs.readFileSync(DATA,"utf8"))}catch(e){}return[]}
function salvar(l){fs.mkdirSync(path.dirname(DATA),{recursive:true});fs.writeFileSync(DATA,JSON.stringify(l,null,2),"utf8")}
function lerState(){try{if(fs.existsSync(STATE))return JSON.parse(fs.readFileSync(STATE,"utf8"))}catch(e){}return null}
function salvarState(s){fs.mkdirSync(path.dirname(STATE),{recursive:true});fs.writeFileSync(STATE,JSON.stringify(s,null,2),"utf8")}
function estadoBase(){return{projetos:[],concluidos:[],excluidos:[],odooIgnored:[],nextId:1,rodizio:0,rev:0}}
function auth(req,res,next){if(!TOKEN)return next();if(req.headers["authorization"]!=="Bearer "+TOKEN)return res.status(401).json({error:"Unauthorized"});next()}
app.get("/entradas",auth,(req,res)=>res.json(ler().filter(e=>e._status==="pendente")));
app.post("/entradas",auth,(req,res)=>{const lista=Array.isArray(req.body)?req.body:[req.body];const todas=ler();const ids=new Set(todas.map(e=>e.id));const novas=[];lista.forEach(item=>{if(!item.nome)return;const e={id:item.id||("wpp_"+crypto.randomUUID()),who:item.who||"WhatsApp",solic:item.solic||item.who||"",nome:(item.nome||"").toUpperCase().trim(),prior:["Alta","Media","Nula"].includes(item.prior)?item.prior:"Nula",prazo:item.prazo||"",nota:item.nota||"",msg:item.msg||"",time:item.time||new Date().toLocaleString("pt-BR",{timeZone:"America/Bahia"}),_status:"pendente",_ts:Date.now()};if(!ids.has(e.id)){todas.push(e);novas.push(e.id);ids.add(e.id)}});salvar(todas);res.json({ok:true,inseridas:novas.length})});
app.delete("/entradas/:id",auth,(req,res)=>{let t=ler();const a=t.length;t=t.filter(e=>e.id!==req.params.id);salvar(t);res.json({ok:true,removidas:a-t.length})});
// ----- ESTADO COMPARTILHADO DO DASHBOARD -----
const APP_VER="v2"; // versão esperada do dashboard que pode gravar
app.get("/state",(req,res)=>{const s=lerState();res.json(s||estadoBase())});
app.post("/state",(req,res)=>{const b=req.body||{};
  // blinda: rejeita gravações de versões antigas do dashboard (evita sobrescrever o estado compartilhado)
  if(b.appVer!==APP_VER){console.warn("[state] gravação rejeitada (versão antiga/ausente)");return res.json({ok:false,ignored:true,reason:"versao_antiga"});}
  const atual=lerState()||estadoBase();const novo={projetos:Array.isArray(b.projetos)?b.projetos:[],concluidos:Array.isArray(b.concluidos)?b.concluidos:[],excluidos:Array.isArray(b.excluidos)?b.excluidos:(atual.excluidos||[]),odooIgnored:Array.isArray(b.odooIgnored)?b.odooIgnored:(atual.odooIgnored||[]),nextId:b.nextId||1,rodizio:b.rodizio||0,rev:(atual.rev||0)+1,_ts:Date.now()};salvarState(novo);res.json({ok:true,rev:novo.rev})});
app.get("/health",(_,res)=>res.json({ok:true,ts:Date.now()}));

// ===== SINCRONIZACAO AUTONOMA COM ODOO (roda no servidor 24/7) =====
const ODOO={url:process.env.ODOO_URL||"https://stand-1.odoo.com",db:process.env.ODOO_DB||"stand-1",login:process.env.ODOO_LOGIN||"projeto@stand1.com.br",key:process.env.ODOO_KEY||""};
const AUTO_MEMBROS=["2. FAGNER","3. GABRIEL"]; // só estes recebem atribuição automática
const ODOO_INTERVAL_MS=2*60*1000;
let _odooUid=null;

async function odooRpc(service,method,args){
  const r=await fetch(ODOO.url+"/jsonrpc",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",method:"call",id:1,params:{service,method,args}})});
  const d=await r.json();
  if(d.error)throw new Error(JSON.stringify(d.error));
  return d.result;
}
async function odooAuth(){
  const uid=await odooRpc("common","authenticate",[ODOO.db,ODOO.login,ODOO.key,{}]);
  console.log("[odoo] auth resultado:",uid);
  return uid;
}

// escolhe o membro auto com menos carga atual
function proximoMembro(projetos){
  let melhor=AUTO_MEMBROS[0],menor=Infinity;
  for(const m of AUTO_MEMBROS){
    const carga=projetos.filter(p=>p.resp===m&&p.status!=="concluido").length;
    if(carga<menor){menor=carga;melhor=m;}
  }
  return melhor;
}
function nowBR(){return new Date().toLocaleString("pt-BR",{timeZone:"America/Bahia",day:"2-digit",month:"2-digit",year:"numeric",hour:"2-digit",minute:"2-digit"});}
// normaliza nome para comparação: minúsculas, sem espaços extras
function normNome(n){return (n||"").toLowerCase().trim().replace(/\s+/g," ");}

async function sincronizarOdoo(){
  try{
    if(!_odooUid)_odooUid=await odooAuth();
    if(!_odooUid){console.warn("[odoo] auth falhou");return;}
    const projs=await odooRpc("object","execute_kw",[ODOO.db,_odooUid,ODOO.key,"project.project","search_read",[[["stage_id.name","=","To Do"]]],{fields:["name","partner_id","user_id"],limit:100}]);
    const st=lerState()||estadoBase();
    const ignorados=st.odooIgnored||[];
    const existentes=new Set([...(st.projetos||[]),...(st.concluidos||[])].filter(p=>p.odooId).map(p=>p.odooId));
    // nomes de projetos ATIVOS (não concluídos) — base da deduplicação
    const nomesAtivos=new Set((st.projetos||[]).filter(p=>p.status!=="concluido").map(p=>normNome(p.nome)));
    // ordena por id ascendente: o mais antigo é o "canônico" que será mantido
    const ordenados=[...(projs||[])].sort((a,b)=>a.id-b.id);
    let novas=0,duplicados=0,mudou=false;
    for(const p of ordenados){
      if(existentes.has(p.id))continue;           // já importado
      if(ignorados.includes(p.id))continue;        // excluído/ignorado
      const norm=normNome(p.name);
      if(nomesAtivos.has(norm)){
        // já existe um projeto ATIVO com o mesmo nome -> duplicado: ignora permanentemente
        ignorados.push(p.id);
        st.odooIgnored=ignorados;
        duplicados++; mudou=true;
        console.log("[odoo] duplicado ignorado: \""+p.name+"\" (odooId "+p.id+")");
        continue;
      }
      const resp=proximoMembro(st.projetos);
      const solic=Array.isArray(p.user_id)?p.user_id[1]:"";
      const cliente=Array.isArray(p.partner_id)?p.partner_id[1]:"";
      st.projetos.unshift({id:(st.nextId||1),nome:p.name,resp,solic,odooId:p.id,status:"fila",prior:"Nula",obs:cliente?("Cliente: "+cliente):"",prazo:"",nota:"",log:[{t:nowBR(),msg:"Criado via Odoo (auto) — atribuído a "+resp,tipo:"blue"}],origem:"odoo"});
      st.nextId=(st.nextId||1)+1;
      existentes.add(p.id);
      nomesAtivos.add(norm);
      novas++; mudou=true;
    }
    if(mudou){st.rev=(st.rev||0)+1;st._ts=Date.now();salvarState(st);console.log("[odoo] importados: "+novas+" | duplicados ignorados: "+duplicados);}
  }catch(e){_odooUid=null;console.error("[odoo] erro detalhado:",e.message,e.stack);}
}

setInterval(sincronizarOdoo,ODOO_INTERVAL_MS);
setTimeout(sincronizarOdoo,5000); // primeira sync logo após iniciar

app.listen(PORT,()=>console.log("Stand1 Bridge porta "+PORT+" (Odoo autonomo ativo)"));
