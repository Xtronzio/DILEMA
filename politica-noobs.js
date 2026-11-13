"use strict";
/* DILEMA · POLÍTICA PARA NOOBS · prototipo multirronda.
   Cada ronda contiene una pregunta nueva, votación privada y debate.
   Las preguntas actuales proceden de un banco editorial, NO de IA generativa.
*/
(()=>{
const sb=window.supabase.createClient("https://cioydzndfvskzubyjcgs.supabase.co","sb_publishable_XrqG0cXWS2vlJIa3jw70Ng_33Gftqes");
const $=id=>document.getElementById(id), KEY="dilema_noobs_room";
const TOPICS={
 vivienda:{title:"VIVIENDA",teaser:"Alquiler, vivienda pública y construcción.",q:[
  ["Un ayuntamiento puede iniciar una sola medida. ¿Cuál elegirías?","Construir vivienda pública para alquiler asequible.","Facilitar licencias y suelo para construir más vivienda.","Las dos medidas llevan tiempo. ¿Qué harías para ayudar este mismo año?"],
  ["Los alquileres de una ciudad suben mucho. ¿Qué probarías primero?","Establecer límites temporales a los precios.","Dar incentivos y garantías para aumentar pisos en alquiler.","¿Cómo medirías si quedan más o menos pisos disponibles?"],
  ["Una pareja joven puede pagar una hipoteca pero no tiene entrada. ¿Qué priorizarías?","Avales y apoyos públicos a la primera vivienda.","Usar esos fondos para ampliar el alquiler público.","¿Y si las ayudas elevan la demanda sin aumentar la oferta?"],
  ["Hay pisos vacíos en un barrio donde cuesta alquilar. ¿Qué harías?","Crear obligaciones o recargos para movilizarlos.","Ofrecer incentivos y seguros para alquilarlos voluntariamente.","¿Qué excepciones admitirías por situaciones personales?"],
  ["Una ciudad turística pierde alquileres de larga duración. ¿Qué harías?","Restringir el uso turístico de viviendas residenciales.","Facilitar nueva construcción y aumentar opciones de alojamiento.","¿Cómo equilibrarías empleo turístico y acceso a la vivienda?"],
  ["Con recursos limitados para vivienda, ¿a quién ayudarías primero?","A quienes tienen los ingresos más bajos.","A quienes intentan independizarse por primera vez.","¿Qué sucede con personas vulnerables que quedan fuera de cada criterio?"],
  ["Un propietario teme impagos y el inquilino teme perder su casa. ¿Qué priorizarías?","Refuerzo de seguridad y estabilidad del inquilino.","Garantías jurídicas y coberturas del propietario.","¿Cómo evitarías desplazar el riesgo de una parte a la otra?"],
  ["Para abaratar la vivienda nueva, ¿por dónde empezarías?","Reservar parte de las promociones a vivienda asequible.","Reducir impuestos y trámites de construcción.","¿Cómo garantizarías que el ahorro llegue a compradores o inquilinos?"]
 ]},
 inmigracion:{title:"INMIGRACIÓN",teaser:"Derechos, vías legales, integración y controles.",q:[
  ["¿Dónde mejorarías primero la gestión migratoria?","Vías legales y programas de integración.","Controles y rapidez de los expedientes.","¿Cómo protegerías los derechos en cualquiera de las dos opciones?"],
  ["Un municipio recibe nuevas familias. ¿Qué priorizarías?","Recursos de acogida e idioma.","Planificación de vivienda y servicios municipales.","¿Qué solución coordinaría ambas necesidades?"],
  ["Para reducir el empleo irregular, ¿por dónde empezarías?","Facilitar vías laborales legales con requisitos claros.","Reforzar la inspección contra empleadores ilegales.","¿Qué medida protegería mejor a las personas explotadas?"],
  ["Una persona solicita protección sin documentos completos. ¿Qué priorizarías?","Tiempo y garantías para evaluar el caso individual.","Procedimientos ágiles con controles eficientes.","¿Cómo conciliarías rapidez y protección de derechos?"]
 ]},
 sanidad:{title:"SANIDAD",teaser:"Recursos, personal y listas de espera.",q:[
  ["Para reducir una lista de espera, ¿qué medida priorizarías?","Contratar profesionales y ampliar recursos.","Reorganizar horarios y uso de equipos.","¿Qué harías si faltan especialistas disponibles?"],
  ["¿Dónde invertirías para mejorar la salud?","Más atención primaria y prevención.","Más capacidad para tratar patologías actuales.","¿Cómo combinarías beneficio futuro y urgencia actual?"],
  ["Un centro rural no cubre plazas. ¿Qué harías primero?","Incentivos para atraer profesionales.","Organizar telemedicina y desplazamientos.","¿Qué casos deben atenderse presencialmente?"],
  ["Con un presupuesto sanitario extra, ¿qué harías?","Aumentar personal y tiempo de consulta.","Actualizar equipos y procesos.","¿Cómo comprobarías qué medida funciona mejor?"]
 ]},
 educacion:{title:"EDUCACIÓN",teaser:"Aprendizaje, igualdad y exigencia.",q:[
  ["Una clase tiene niveles muy diferentes. ¿Qué priorizarías?","Apoyos personalizados.","Criterios comunes y mayor exigencia.","¿Cómo combinarías ambas sin dejar a nadie atrás?"],
  ["Un centro recibe presupuesto extra. ¿En qué lo invertirías?","Más profesorado y grupos reducidos.","Formación y mejores recursos educativos.","¿Cómo comprobarías el resultado de ambas opciones?"],
  ["¿Cómo evaluarías a los alumnos?","Valorar la evolución y las dificultades individuales.","Establecer conocimientos comunes demostrables.","¿Qué enfoque combina equidad con aprendizaje?"],
  ["Para combatir desigualdades educativas, ¿qué harías?","Dar más apoyo a centros con necesidades mayores.","Mejorar estándares comunes para todos.","¿Con qué datos compararías ambas medidas?"]
 ]},
 impuestos:{title:"IMPUESTOS",teaser:"Ingresos personales y servicios públicos.",q:[
  ["Si debes elegir una prioridad fiscal, ¿cuál sería?","Bajar impuestos para aumentar renta disponible.","Mantener ingresos para financiar servicios.","¿Qué servicios o impuestos cambiarían tu decisión?"],
  ["¿Qué principio tributario te parece preferible?","Contribución mayor de quienes tienen más capacidad.","Tipos más bajos y reglas simples para todos.","¿Qué datos necesitarías para valorar sus efectos?"],
  ["Si hay ingresos públicos inesperados, ¿qué priorizarías?","Rebajas tributarias o reducir deuda.","Mejorar servicios o invertir en infraestructuras.","¿Cuánto reservarías para una próxima crisis?"],
  ["Una pyme quiere contratar, pero tiene costes altos. ¿Qué le ayudaría más?","Incentivos fiscales a contratar.","Formación y servicios para mejorar productividad.","¿Cómo comprobarías que se genera empleo adicional?"]
 ]},
 empleo:{title:"EMPLEO",teaser:"Salarios, contratación y estabilidad.",q:[
  ["Para mejorar empleos con bajos ingresos, ¿qué priorizarías?","Mejorar salarios y derechos laborales.","Incentivos para crear más puestos y productividad.","¿Cómo atenderías a pequeñas empresas con márgenes ajustados?"],
  ["Para acceder al primer empleo, ¿qué medida probarías?","Bonificaciones a la primera contratación.","Más formación práctica remunerada.","¿Cómo impedirías que una ayuda sustituya empleos estables?"],
  ["¿Qué problema laboral atenderías primero?","Precariedad y temporalidad.","Dificultad de cambio entre empresas y sectores.","¿Qué harías con los trabajos estacionales?"],
  ["Para retener talento, ¿qué medida priorizarías?","Mejores salarios y formación.","Condiciones para invertir y emprender.","¿Cuándo convendría combinar ambas?"]
 ]},
 medioambiente:{title:"ENERGÍA Y CLIMA",teaser:"Contaminación, precios y transición.",q:[
  ["Ante una transición energética costosa, ¿qué priorizarías?","Reducir emisiones cuanto antes.","Proteger precios accesibles y empleo.","¿Cómo distribuirías los costes iniciales?"],
  ["Una fábrica contamina pero crea mucho empleo. ¿Qué harías?","Acelerar los límites ambientales.","Permitir más tiempo con objetivos verificables.","¿Qué garantías exigirías a la empresa?"],
  ["¿Qué inversión energética priorizarías?","Nueva generación renovable.","Almacenamiento y seguridad de suministro.","¿Cómo responderías a picos de demanda?"],
  ["Para reducir contaminación del transporte, ¿qué harías?","Mejorar transporte público.","Facilitar vehículos menos contaminantes.","¿Qué pasa con quienes viven lejos de las ciudades?"]
 ]},
 seguridad:{title:"SEGURIDAD Y JUSTICIA",teaser:"Prevención, respuesta y derechos.",q:[
  ["Para mejorar la seguridad, ¿por dónde empezarías?","Prevención y reducción de reincidencia.","Policía y justicia más ágiles.","¿Cómo combinarías prevención futura y protección inmediata?"],
  ["Si la justicia recibe nuevos recursos, ¿dónde invertirías?","Apoyos y protección a víctimas.","Agilizar procesos judiciales.","¿Cómo mantener las garantías si se aceleran los juicios?"],
  ["Tras cumplir condena, ¿qué priorizarías?","Reinserción para evitar nuevos delitos.","Seguimiento para proteger a otras personas.","¿Cómo medirías resultados y derechos?"],
  ["La tecnología puede ayudar a investigar delitos. ¿Qué priorizarías?","Más límites a vigilancia y datos personales.","Nuevas herramientas con control judicial.","¿Qué controles aceptarías sobre la privacidad?"]
 ]}
};
const PARTIES=["PP","PSOE","Vox","Frente Amplio","Podemos","PNV","EH Bildu","SALF","PCTE"];
const PDF={
 PP:"https://www.pp.es/wp-content/uploads/2026/11/LA-RECONSTRUCCION-NACIONAL.pdf",
 Vox:"https://www.voxespana.es/wp-content/uploads/2026/11/Programa-completo-A5-1.pdf",
 PNV:"https://www.eaj-pnv.eus/es/adjuntos-documentos/21765/pdf/programa-electoral-29n",
 SALF:"https://www.seacabolafiesta.com/SALF_Contrato_Electoral_29N.pdf?v=073425b9522d"
};
const EVIDENCE={
 vivienda:[
  {p:"PP",type:"Programa 29N 2026 · medidas 144–156",t:"Propone aumentar la construcción, agilizar licencias y facilitar la primera vivienda de los jóvenes mediante medidas fiscales y avales.",url:PDF.PP,page:"53–56"},
  {p:"Vox",type:"Programa 29N 2026 · medidas 26–34",t:"Plantea ampliar suelo y vivienda protegida, derogar la Ley de Vivienda y establecer prioridad nacional en vivienda social y ayudas.",url:PDF.Vox,page:"23–25"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 1.1",t:"Propone facilitar nuevas viviendas, rehabilitar y movilizar viviendas vacías, y regular los alquileres temporales y turísticos.",url:PDF.PNV,page:"7–8"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 1",t:"Promete eliminar la carga fiscal de la primera vivienda, simplificar licencias y facilitar financiación hipotecaria; los efectos de ahorro son afirmaciones del propio partido.",url:PDF.SALF,page:"4–6"}
 ],
 inmigracion:[
  {p:"PP",type:"Programa 29N 2026 · medida 35",t:"Propone una autoridad única para coordinar entrada, permanencia, retorno e integración y evaluar sus efectos.",url:PDF.PP,page:"21"},
  {p:"Vox",type:"Programa 29N 2026 · medidas 9–17",t:"Plantea prohibir regularizaciones masivas, suprimir el arraigo y reforzar controles y repatriaciones.",url:PDF.Vox,page:"15–16"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 3.2",t:"Propone más competencias vascas en gestión migratoria, vías legales y ordenadas, acogida e integración laboral.",url:PDF.PNV,page:"24–25"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 4",t:"Plantea limitar la inmigración a vías legales y agilizar expulsiones en los supuestos que describe.",url:PDF.SALF,page:"4"}
 ],
 sanidad:[
  {p:"PP",type:"Programa 29N 2026 · medidas 219–223",t:"Propone un plan de reducción de listas de espera, más personal de atención primaria, prevención y refuerzo de salud mental.",url:PDF.PP,page:"69–70"},
  {p:"Vox",type:"Programa 29N 2026 · medidas 60–65",t:"Propone tarjeta sanitaria común, refuerzo de atención primaria y un plan nacional para reducir listas de espera.",url:PDF.Vox,page:"37–38"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 4.2",t:"Propone ajustar la formación de especialistas a las necesidades sanitarias y completar competencias sanitarias de Euskadi.",url:PDF.PNV,page:"31–32"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 6",t:"Propone una central de compras sanitarias, reducir la espera quirúrgica y revisar remuneraciones profesionales.",url:PDF.SALF,page:"4"}
 ],
 educacion:[
  {p:"PP",type:"Programa 29N 2026 · medidas 209–218",t:"Propone refuerzo temprano en lectura y cálculo, apoyo a alumnado con dificultades y una revisión del marco educativo.",url:PDF.PP,page:"67–69"},
  {p:"Vox",type:"Programa 29N 2026 · medidas 66–69",t:"Propone currículo y evaluaciones comunes, libertad de elección de centro, cambios legislativos y refuerzo de becas.",url:PDF.Vox,page:"41"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 1.4",t:"Defiende las competencias educativas de Euskadi y una educación inclusiva, plurilingüe e intercultural.",url:PDF.PNV,page:"10"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 9",t:"Propone una ley educativa de larga duración, garantías de escolarización en castellano y financiación vinculada al alumno.",url:PDF.SALF,page:"4"}
 ],
 impuestos:[
  {p:"PP",type:"Programa 29N 2026 · medidas 177–185",t:"Propone bajar el IRPF para rentas medias y bajas, actualizar mínimos personales y familiares y deflactar la tarifa.",url:PDF.PP,page:"61–62"},
  {p:"Vox",type:"Programa 29N 2026 · medida 2",t:"Propone simplificar y reducir el IRPF, bajar parte del IVA y cuotas de autónomos según ingresos.",url:PDF.Vox,page:"9–10"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 2.7",t:"Propone revisar el IVA de ciertos bienes esenciales y reforzar la autonomía fiscal y financiera de Euskadi.",url:PDF.PNV,page:"20–21"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 3",t:"Propone una exención de IRPF para los primeros 35.000 euros de renta.",url:PDF.SALF,page:"4"}
 ],
 empleo:[
  {p:"PP",type:"Programa 29N 2026 · medidas 170–174",t:"Propone incentivos para nuevos autónomos, beneficios a primeras contrataciones y menos cotización para empresas con estabilidad laboral.",url:PDF.PP,page:"59–60"},
  {p:"Vox",type:"Programa 29N 2026 · medidas 2 y 8",t:"Plantea menores cargas fiscales a empresas y autónomos, incentivos a la innovación y una política de reindustrialización.",url:PDF.Vox,page:"9–12"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 1.3",t:"Defiende un salario mínimo propio en Euskadi, negociación colectiva y la protección del empleo estable.",url:PDF.PNV,page:"9"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 8",t:"Plantea reducir cargas laborales, un contrato único con mochila y eliminar la cuota de autónomos.",url:PDF.SALF,page:"4"}
 ],
 medioambiente:[
  {p:"PP",type:"Programa 29N 2026 · medida 228",t:"Propone revisar el calendario de cierre nuclear y combinar nuclear, renovables, almacenamiento y respaldo eléctrico.",url:PDF.PP,page:"71"},
  {p:"Vox",type:"Programa 29N 2026 · medida 8",t:"Propone revisar normas del Pacto Verde, prorrogar centrales nucleares y reducir los impuestos sobre la energía.",url:PDF.Vox,page:"11–12"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 2.4",t:"Propone rehabilitación energética, autoconsumo compartido, electrificación y adaptación al cambio climático.",url:PDF.PNV,page:"16–17"}
 ],
 seguridad:[
  {p:"Vox",type:"Programa 29N 2026 · medidas 79–91",t:"Propone aumentar recursos policiales y de defensa, endurecer ciertas respuestas penales y reforzar ciberseguridad.",url:PDF.Vox,page:"45–47"},
  {p:"PNV",type:"Programa 29N 2026 · apartado 3.1",t:"Plantea más capacidad operativa para la Ertzaintza, cooperación policial europea y medidas contra la multirreincidencia.",url:PDF.PNV,page:"23–24"},
  {p:"SALF",type:"Contrato electoral simplificado 29N · compromiso 2",t:"Propone una macrocárcel y medidas penales específicas contra corrupción y delitos graves.",url:PDF.SALF,page:"4"}
 ]
};
const el=(tag,cls,txt)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(txt!==undefined)n.textContent=txt;return n;};
let state=null,roomId=null,vote=null,angle=null,working=false,runFingerprint="";
let soloMessages=[],soloRound=null,questionCache=[],questionCacheRoom=null,aura="ready";
let sentencePending=false,sentenceAttemptedCycle=null;
const expandedHistory=new Set();
let noticeTimer=null;
const session=()=>roomId?sessionStorage.setItem(KEY,roomId):sessionStorage.removeItem(KEY);
function notice(message){
 const note=$("notice");note.textContent=message||"";
 if(noticeTimer)clearTimeout(noticeTimer);
 if(message)noticeTimer=setTimeout(()=>{if(note.textContent===message)note.textContent="";},4800);
}
async function auth(){
 const current=await sb.auth.getUser();
 if(current.data&&current.data.user)return current.data.user;
 const ret=await sb.auth.signInAnonymously();
 if(ret.error)throw ret.error;
 return ret.data.user;
}
async function rpc(fn,arg){const r=await sb.rpc(fn,arg);if(r.error)throw r.error;return r.data;}
async function execute(fn){
 if(working)return;
 working=true;
 try{await fn();}catch(e){notice("No se pudo completar: "+String(e&&e.message||"error de conexión"));}
 finally{working=false;}
}
function rand(n){const a=new Uint32Array(1);crypto.getRandomValues(a);return a[0]%n;}
function chooseQuestion(id,prior){
 const t=TOPICS[id];
 const used=new Set((prior||[]).map(x=>String(x.question||"").trim().toLocaleLowerCase("es")));
 const easy=state?.audience==="teen_early"||state?.audience==="teen"||state?.audience==="mixed";
 const source=(easy&&t.easy&&t.easy.length?t.easy:[...(t.easy||[]),...t.q]);
 const available=source.filter(x=>!used.has(x[0].toLocaleLowerCase("es")));
 if(!available.length)throw Error("Ya hemos debatido las preguntas preparadas de este Hot Point. Puedes elegir otra temática.");
 const item=available[rand(available.length)];
 if(rand(2)===0)return {question:item[0],a:item[1],b:item[2],twist:item[3]};
 return {question:item[0],a:item[2],b:item[1],twist:item[3]};
}
function choosePulseTopic(){
 const done=new Set((questionCache||[]).filter(x=>x.kind==="pulse").map(x=>x.topic));
 const fresh=Object.keys(TOPICS).filter(x=>!done.has(x));
 const options=fresh.length?fresh:Object.keys(TOPICS);
 return options[rand(options.length)];
}
async function nextQuestion(id){
 await execute(async()=>{
  if(!roomId||!state||!state.can_act)throw Error("Ahora es el turno de otra persona.");
  if(!["lobby","discussion"].includes(state.phase)||state.closing_open)throw Error("Esta ronda o la votación de cierre sigue abierta.");
  if(state.stage==="pulse"){
   if(Number(state.pulse_count)>=Number(state.pulse_goal))throw Error("El primer pulso ha terminado. Entrad al debate.");
   id=choosePulseTopic();
  }
  if(!TOPICS[id])throw Error("Elige uno de los temas disponibles.");
  notice("DILEMA está preparando una pregunta diferente...");
  const prior=await rpc("politics_questions_used",{p_room:roomId});
  let p=null,mode="CATÁLOGO";
  try{
   const res=await sb.functions.invoke("politics-moderator",{body:{action:"next",room_id:roomId,topic:id}});
   if(res.error)throw res.error;
   const c=res.data&&res.data.card;
   if(c&&typeof c.q==="string"&&typeof c.a==="string"&&typeof c.b==="string"&&typeof c.twist==="string"&&
      c.q.length>18&&c.a.length>10&&c.b.length>10&&
      !prior.some(x=>x.question.trim().toLocaleLowerCase("es")===c.q.trim().toLocaleLowerCase("es"))){
     p={question:c.q,a:c.a,b:c.b,twist:c.twist};mode="IA";
   }
  }catch(err){console.warn("IA no disponible; utilizando banco editorial",String(err&&err.message||err));}
  if(!p)p=chooseQuestion(id,prior);
  let result;
  try{result=await rpc("politics_advance",{p_room:roomId,p_topic:id,p_question:p.question,p_a:p.a,p_b:p.b,p_twist:p.twist});}
  catch(err){
    if(mode!=="IA")throw err;
    p=chooseQuestion(id,prior);mode="CATÁLOGO";
    result=await rpc("politics_advance",{p_room:roomId,p_topic:id,p_question:p.question,p_a:p.a,p_b:p.b,p_twist:p.twist});
  }
  state=result;vote=null;angle=null;aura="ready";runFingerprint="";soloMessages=[];soloRound=null;
  questionCache=Array.isArray(prior)?prior.concat([{cycle:Number(state.cycle),topic:id,kind:state.stage,question:p.question,A:p.a,B:p.b}]):[];
  questionCacheRoom=roomId;
  render();setTab("debate");
  requestAnimationFrame(()=>{const pane=$("noobsScroll");if(pane)pane.scrollTop=pane.scrollHeight;});
  notice((state.stage==="pulse"?"PRIMER PULSO · ":"")+ (mode==="IA"?"Pregunta de DILEMA. Todos votáis.":"Pregunta del catálogo. Todos votáis."));
 });
}
async function loadQuestionHistory(){
 if(!roomId)return;
 const loadedRoom=roomId;
 try{
  const list=await rpc("politics_questions_used",{p_room:loadedRoom});
  if(roomId!==loadedRoom)return;
  questionCache=Array.isArray(list)?list:[];
  questionCacheRoom=loadedRoom;
 }catch(error){
  console.warn("No se pudo recuperar el historial de preguntas",String(error&&error.message||error));
 }
}
function renderQuestionHistory(){
 const root=$("questionHistory");root.replaceChildren();
 if(!state)return;
 const entries=(questionCacheRoom===roomId?questionCache:[])
  .filter(x=>Number(x.cycle)<Number(state.cycle))
  .sort((a,b)=>Number(a.cycle)-Number(b.cycle));
 const closed=state.history||[];
 entries.forEach(q=>{
  const n=Number(q.cycle),item=el("details","noobs-entry"),top=el("summary");
  item.open=expandedHistory.has(n);
  top.append(el("span","noobs-number",String(n)),el("span","noobs-summary",q.question),el("span","noobs-expand","›"));
  item.append(top);
  const body=el("div","noobs-entry-body");
  body.append(el("p","","A · "+q.A),el("p","","B · "+q.B));
  const row=closed.find(x=>Number(x.cycle)===n);
  if(row){
   const total=Number(row.A||0)+Number(row.B||0)+Number(row.N||0);
   const pct=x=>total?Math.round(Number(row[x]||0)*100/total):0;
   body.append(el("p","fine","RESULTADO · A "+pct("A")+" % · B "+pct("B")+" % · DUDAS "+pct("N")+" %"));
  }else body.append(el("p","fine","Esta pregunta ya se ha cerrado."));
  item.append(body);
  item.addEventListener("toggle",()=>{if(item.open)expandedHistory.add(n);else expandedHistory.delete(n);});
  root.append(item);
 });
}
function setTab(name){
 document.querySelectorAll("[data-tab]").forEach(x=>x.setAttribute("aria-selected",String(x.dataset.tab===name)));
 ["hotpoints","debate","mapa"].forEach(x=>$(x).hidden=x!==name);
 document.body.classList.toggle("noobs-fullscreen",!!state&&name==="debate");
 if(name==="mapa")renderMap();
}
function renderHotpoints(){
 const root=$("hotpointCards");root.replaceChildren();
 Object.entries(TOPICS).forEach(pair=>{
  const id=pair[0],t=pair[1],card=el("article","card");
  card.append(el("h3","",t.title),el("p","small muted",t.teaser));
  const b=el("button","btn small","DEBATIR ESTE TEMA");
  if(!state||state.stage!=="debate"||!state.can_act||!["lobby","discussion"].includes(state.phase)||state.closing_open)b.disabled=true;
  b.onclick=()=>nextQuestion(id);
  card.append(b);root.append(card);
 });
}
function renderRoom(){
 document.body.classList.toggle("noobs-in-room",!!state);
 $("noobsGlobalNav").hidden=!state;
 $("roomSetup").hidden=!!state;
 $("roomInfo").hidden=!state;
 if(!state)return;
 $("roomCode").textContent=state.code;
 $("noobsRoomMeta").textContent="SALA "+state.code+" · "+state.count+"/"+state.expected+" PERSONAS";
 const phases={lobby:"SALA PREPARADA",voting:"VOTACIÓN",discussion:"DEBATE",reveal:"SIGLAS REVELADAS"};
 $("roomStatus").textContent=state.count+" de "+state.expected+" participantes · "+(state.stage==="pulse"?"PRIMER PULSO · ":"")+(phases[state.phase]||state.phase);
 const root=$("members");root.replaceChildren();
 (state.participants||[]).forEach((m,i)=>root.append(el("span","person",(state.phase==="discussion"&&i===state.turn?"🎤 ":"")+m.name+(m.host?" · ANFITRIÓN":""))));
}
function renderPulseSummary(){
 const isReady=!!state&&state.stage==="debate";
 $("pulseSummary").hidden=!isReady;
 const records=state?.history||[];
 const pulse=records.filter(x=>questionCache.some(q=>q.kind==="pulse"&&Number(q.cycle)===Number(x.cycle)));
 $("pulseSummaryText").textContent=pulse.length+" preguntas rápidas de temas distintos. No hay respuestas correctas ni se asignan etiquetas políticas.";
 const out=$("pulseDivergences");out.replaceChildren();
 const different=pulse.filter(x=>Number(x.A)>0&&Number(x.B)>0);
 if(different.length){
  out.append(el("p","small","Hubo opiniones diferentes en "+different.length+" pregunta"+(different.length===1?"":"s")+". Pueden servir para empezar a conversar."));
  different.slice(0,4).forEach(x=>{
   const q=questionCache.find(q=>Number(q.cycle)===Number(x.cycle));
   out.append(el("div","result",((TOPICS[x.topic]||{}).title||x.topic)+" · "+(q?.question||"Pregunta "+x.cycle)));
  });
 }else out.append(el("p","small","En el primer pulso no surgieron respuestas opuestas entre A y B. El debate puede explorar los matices de esas elecciones."));
}
function renderDebate(){
 const active=!!state,phase=state?.phase,stage=state?.stage||"pulse";
 const pulse=stage==="pulse",debating=stage==="debate",discussion=phase==="discussion",voting=phase==="voting";
 const onTurn=!!state?.can_act,canInteract=debating&&discussion&&!state.closing_open&&onTurn;
 const allowPulse=pulse&&onTurn&&["lobby","discussion"].includes(phase);
 $("phaseTitle").textContent=active?(pulse?"PRIMER PULSO · "+state.pulse_count+"/"+state.pulse_goal:
  (TOPICS[state.topic]?.title||"DEBATE")):"DEBATE COMPARTIDO";
 $("stageSubtitle").textContent=active?(pulse?"VOTAMOS PRIMERO · HABLAMOS DESPUÉS":
  phase==="reveal"?"SENTENCIA DE DILEMA · PROGRAMAS REALES":"UNA PREGUNTA · UN VOTO · UN DEBATE"):"";
 $("ballotBlock").hidden=!voting;
 $("discussionBlock").hidden=!discussion;
 $("revealBlock").hidden=phase!=="reveal";
 $("closingBlock").hidden=!(debating&&discussion&&state.closing_open);
 $("discussionTurn").hidden=!canInteract&&!(debating&&discussion)||pulse||state?.closing_open;
 $("pulseControls").hidden=!allowPulse;
 $("nextPulse").hidden=!allowPulse||state.pulse_count>=state.pulse_goal;
 $("startDeepDebate").hidden=!allowPulse||state.pulse_count<state.pulse_goal;
 $("hostControls").hidden=!canInteract;
 $("revote").hidden=!canInteract;
 $("reveal").hidden=!canInteract;
 $("another").hidden=!state?.host;
 $("nextTurn").hidden=!canInteract||Number(state?.count)===1;
 $("politicsTools").hidden=!canInteract;
 $("soloComposer").hidden=!(canInteract&&Number(state?.count)===1);
 $("soloDialogue").hidden=!(debating&&discussion&&Number(state?.count)===1&&!state.closing_open);
 $("groupSummary").hidden=!(canInteract&&Number(state?.count)>1);
 $("discussionTurn").hidden=!(debating&&discussion&&!state.closing_open);
 if(!onTurn)$("nextTurn").hidden=true;
 $("closingChoices").hidden=!(debating&&discussion&&state.closing_open);
 $("closingStatus").textContent=state?.closing_open?
  "Han votado "+state.closing_voted+" de "+state.count+". Cada persona decide si quiere terminar.":"";
 const sharedAura=discussion&&typeof state?.twist==="string"
  ?(/^CONTRADÍCEME:/i.test(state.twist)?"counter":/^PUNTO CIEGO:/i.test(state.twist)?"blind":
  /^OTRA MIRADA:/i.test(state.twist)?"view":null):null;
 const currentAura=voting?"vote":discussion?(sharedAura||aura):"ready";
 $("noobsShell").dataset.aura=currentAura;
 const titles={ready:"DILEMA · TE ESCUCHO",vote:"DILEMA · VOTACIÓN",
  counter:"CONTRADÍCEME",blind:"PUNTO CIEGO",view:"OTRA MIRADA",pressure:"APRIÉTAME",order:"ORDENA ESTO"};
 $("dialogueStatus").textContent=pulse?"PRIMER PULSO · DILEMA PREGUNTA":
  (titles[currentAura]||titles.ready);
 $("liveQuestionTitle").hidden=!active||phase==="lobby"||voting;
 if(active){
  $("liveQuestionNumber").textContent=String(state.cycle);
  $("liveQuestionText").textContent=state.question||"";
 }
 renderPulseSummary();
 document.querySelectorAll("[data-giro]").forEach(btn=>btn.disabled=!canInteract);
 if(!active){$("phaseDetail").textContent="Crea una sala o únete con su código para comenzar.";return;}
 if(phase==="lobby"){
  $("phaseDetail").textContent=pulse?
    "Cuando todos estéis conectados, comenzad seis votaciones rápidas de temas distintos.":
    "Ya tenemos el primer pulso. Elegid un Hot Point para empezar a debatir con más profundidad.";
  return;
 }
 if(voting){
  $("phaseDetail").textContent="Han votado "+state.voted+" de "+state.count+". Los resultados no aparecen hasta que voten todos.";
  $("voteContext").textContent=(pulse?"PULSO "+state.pulse_count+" DE "+state.pulse_goal:
   "DEBATE · PREGUNTA "+state.cycle)+" · VOTACIÓN SIN SIGLAS";
  $("voteQuestion").textContent=state.question;
  $("twistText").textContent=pulse?"Vota lo que te parezca. Ahora no hay que defender la respuesta.":
   "Luego podrás explicar por qué has elegido tu opción.";
  const root=$("voteChoices");root.replaceChildren();
  [["A",state.A],["B",state.B],["N","DEPENDE / NECESITO MÁS INFORMACIÓN"]].forEach(pair=>{
   const val=pair[0],lab=el("label","choice"),radio=el("input");
   radio.type="radio";radio.name="voto";radio.value=val;radio.checked=(vote||state.my_vote)===val;
   radio.onchange=()=>{vote=val;$("submitVote").disabled=false;};
   lab.append(radio,el("span","",pair[1]));root.append(lab);
  });
  $("submitVote").disabled=!(vote||state.my_vote);
  $("submitVote").textContent=state.my_vote?"CAMBIAR MI VOTO":"VOTAR";
 }
 if(discussion){
  $("phaseDetail").textContent=pulse?
   (state.pulse_count>=state.pulse_goal?"Primer pulso terminado. Ahora empieza el debate.":"Votación cerrada. Todavía no debatimos: continuamos con otro tema."):
   (state.closing_open?"La mesa está votando si termina el debate.":
    onTurn?"Ahora tienes la palabra. Solo tú puedes pedir objeciones, pasar el turno o abrir otra pregunta.":
    "Escucha a quien tiene la palabra. Podrás intervenir cuando te llegue el turno.");
  const count=Number(state.count)||1,t=state.tally||{A:0,B:0,N:0},out=$("voteResults");out.replaceChildren();
  [["A",state.A],["B",state.B],["N","Depende / no lo sé"]].forEach(pair=>{
   const n=Number(t[pair[0]]||0),pct=count?Math.round(100*n/count):0,row=el("div","result");
   row.append(el("b","",pair[0]+" · "+pct+" % · "+n+" voto"+(n===1?"":"s")),el("p","",pair[1]));out.append(row);
  });
  if(!pulse){
   $("speaker").textContent=(state.participants[state.turn]||{}).name||"Participante";
   $("moderatorQuestion").textContent=angle||state.twist||"¿Qué argumento te haría revisar tu respuesta?";
  }
  if(debating&&Number(state.count)===1){
   if(soloRound!==state.cycle){soloRound=state.cycle;soloMessages=[];$("soloArgument").value="";}
   renderSoloMessages();
  }
 }
 if(phase==="reveal"){
  $("phaseDetail").textContent="La mesa ha decidido cerrar. DILEMA resume las diferencias y después revela las fuentes.";
  $("sentenceText").textContent=state.sentence?
   state.sentence+"\n\n"+(state.sentence_question||""):
   (state.can_act?"DILEMA está preparando la sentencia...":"Esperando la sentencia del turno actual...");
  $("requestSentence").hidden=!!state.sentence||!onTurn;
  renderSources();
  if(onTurn&&!state.sentence&&sentenceAttemptedCycle!==state.cycle){
   sentenceAttemptedCycle=state.cycle;
   setTimeout(()=>requestSentence(),350);
  }
 }
}
function renderSources(){
 const root=$("partySources");root.replaceChildren();
 const topics=[...new Set((questionCache||[]).map(q=>q.topic).filter(x=>TOPICS[x]))];
 if(!topics.length&&state?.topic)topics.push(state.topic);
 topics.forEach(topic=>{
  const section=el("details","noobs-entry"),head=el("summary");
  head.append(el("span","noobs-summary",(TOPICS[topic]||{}).title||topic),el("span","noobs-expand","›"));
  section.append(head);
  const body=el("div","noobs-entry-body"),refs=EVIDENCE[topic]||[];
  PARTIES.forEach(p=>{
   const item=el("div","result"),source=refs.find(x=>x.p===p);
   item.append(el("b","",p));
   if(source){
    item.append(el("div","label",source.type),el("p","",source.t));
    if(source.page)item.append(el("div","fine","Páginas: "+source.page));
    const link=el("a","","VER PROGRAMA OFICIAL");link.href=source.url;
    link.target="_blank";link.rel="noopener noreferrer";item.append(link);
   }else item.append(el("p","","Esta propuesta todavía no está documentada para este tema. No se presupone ninguna postura."));
   body.append(item);
  });
  section.append(body);root.append(section);
 });
}
function sentenceFallback(){
 const rounds=state?.history||[];
 const pulse=rounds.filter(h=>questionCache.some(q=>q.kind==="pulse"&&Number(q.cycle)===Number(h.cycle))).length;
 const debated=rounds.length-pulse;
 const divisions=rounds.filter(x=>Number(x.A)>0&&Number(x.B)>0).length;
 return {
  summary:"La mesa ha votado "+rounds.length+" preguntas, de ellas "+pulse+
   " del primer pulso y "+debated+" del debate. En "+divisions+
   " votaciones hubo respuestas distintas entre A y B. Ese resultado no basta para saber qué piensa cada participante sobre todo el programa de un partido. Lo valioso son los argumentos que habéis puesto sobre la mesa.",
  question:"¿Qué pregunta volveríais a debatir después de escuchar las razones de todos?"
 };
}
async function requestSentence(){
 if(!roomId||!state||state.phase!=="reveal"||!state.can_act||state.sentence||sentencePending||working)return;
 sentencePending=true;
 try{
  const fallback=sentenceFallback();
  let statement=fallback;
  try{
   const r=await sb.functions.invoke("politics-moderator",{body:{action:"sentence",room_id:roomId}});
   if(r.error)throw r.error;
   if(typeof r.data?.summary==="string"&&typeof r.data?.openQuestions==="string"){
    statement={summary:r.data.summary,question:r.data.openQuestions};
   }
  }catch(e){console.warn("No se pudo generar sentencia IA",String(e?.message||e));}
  state=await rpc("politics_save_sentence",{p_room:roomId,p_summary:statement.summary,p_question:statement.question});
  render();
 }catch(e){notice("No se pudo guardar la sentencia: "+String(e?.message||e));}
 finally{sentencePending=false;}
}
function renderMap(){
 const root=$("ideaMap");root.replaceChildren();
 if(!state||!state.history||!state.history.length){root.append(el("div","box","Aquí aparecerán los porcentajes de cada votación cerrada."));return;}
 state.history.forEach(h=>{
  const n=Number(h.A||0)+Number(h.B||0)+Number(h.N||0);
  const pct=k=>n?Math.round(Number(h[k]||0)*100/n):0,c=el("div","card");
  c.append(el("div","label",(TOPICS[h.topic]&&TOPICS[h.topic].title||h.topic)+" · RONDA "+h.cycle),
   el("h3","","A "+pct("A")+" % · B "+pct("B")+" % · DUDAS "+pct("N")+" %"),
   el("p","fine",n+" votos. Son porcentajes de respuestas, no de afinidad con partidos."));
  root.append(c);
 });
}
function renderSoloMessages(){
 const root=$("soloMessages");root.replaceChildren();
 soloMessages.forEach(x=>{
  const card=el("div","detail");
  card.append(el("div","label",x.role),el("p","small",x.text));
  root.append(card);
 });
 $("sendArgument").disabled=soloMessages.filter(x=>x.role==="TÚ").length>=5;
}
function render(){renderRoom();renderHotpoints();renderQuestionHistory();renderDebate();renderMap();}
async function refresh(){
 if(!roomId||working)return;
 try{
  const s=await rpc("politics_state",{p_room:roomId}),was=state&&state.cycle,phase=state&&state.phase;
  state=s;
  if(was!==s.cycle||questionCacheRoom!==roomId)await loadQuestionHistory();
  const fp=JSON.stringify([s.cycle,s.phase,s.stage,s.pulse_count,s.can_act,s.voted,s.count,s.turn,s.my_vote,s.topic,s.twist,s.closing_open,s.closing_voted,s.my_closing_vote,s.sentence]);
  if(fp!==runFingerprint){
   runFingerprint=fp;if(was!==s.cycle||phase!==s.phase){vote=null;angle=null;aura="ready";}render();
  }
 }catch(e){notice("No se pudo actualizar la sala: "+String(e&&e.message||"error"));}
}
function leave(){
 roomId=null;state=null;questionCache=[];questionCacheRoom=null;expandedHistory.clear();aura="ready";sentenceAttemptedCycle=null;
 document.body.classList.remove("noobs-fullscreen");
 session();history.replaceState(null,"",location.pathname);
 render();setTab("hotpoints");notice("Has salido. La sala seguirá hasta que el anfitrión la cierre.");
}
async function copy(s){
 try{await navigator.clipboard.writeText(s);notice("Copiado.");}
 catch{notice("Copia este texto: "+s);}
}
async function init(){
 for(let i=1;i<=20;i++){
  const opt=el("option","",String(i));opt.value=String(i);if(i===4)opt.selected=true;
  $("participantsExpected").append(opt);
 }
 $("roomJoin").value=(new URLSearchParams(location.search).get("room")||"").toUpperCase().slice(0,10);
 function updateAgeHint(){
  const count=Number($("participantsExpected").value)||1;
  $("ageHint").textContent=(count===1?
    "Indica tu edad en años. Ejemplo: 14.":
    "Indica "+count+" edades separadas por comas. Ejemplo: 13, 15, 45, 48.")+
    " Solo sirven para adaptar el lenguaje; no se guardan individualmente.";
  $("ageList").placeholder=count===1?"14":count===2?"13, 45":count===4?"13, 15, 45, 48":"Una edad por participante";
 }
 $("participantsExpected").addEventListener("change",updateAgeHint);
 updateAgeHint();
 document.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
 document.querySelectorAll("[data-open-tab]").forEach(b=>b.onclick=()=>setTab(b.dataset.openTab));
 $("create").onclick=()=>execute(async()=>{
  if(!$("consent").checked)throw Error("Marca el consentimiento de participación para continuar.");
  const expected=Number($("participantsExpected").value);
  const typed=$("ageList").value.trim();
  const ages=typed.split(/[;,\s]+/).filter(Boolean).map(Number);
  if(ages.length!==expected||!ages.every(x=>Number.isInteger(x)&&x>=12&&x<=100)){
    throw Error("Indica "+expected+" edad"+(expected===1?"":"es")+" (entre 12 y 100 años), separadas por comas.");
  }
  await auth();const r=await rpc("politics_new_room_ages",{p_name:$("alias").value.trim(),p_expected:expected,p_consent:true,p_ages:ages});
  roomId=r.room_id;session();state=await rpc("politics_state",{p_room:roomId});await loadQuestionHistory();render();setTab("hotpoints");
 });
 $("join").onclick=()=>execute(async()=>{
  if(!$("consent").checked)throw Error("Marca el consentimiento de participación para continuar.");
  await auth();const r=await rpc("politics_join_room_safe",{p_code:$("roomJoin").value.trim().toUpperCase(),p_name:$("alias").value.trim(),p_consent:true});
  roomId=r.room_id;session();state=await rpc("politics_state",{p_room:roomId});await loadQuestionHistory();render();setTab("debate");
 });
 $("share").onclick=()=>copy(location.origin+location.pathname+"?room="+encodeURIComponent(state&&state.code||""));
 $("refresh").onclick=refresh;
 $("leave").onclick=()=>execute(async()=>{
  if(!state||!roomId)return leave();
  if(state.host&&!confirm("Si abandonas como anfitrión se cerrará esta sala y se eliminarán todos sus votos. ¿Continuar?"))return;
  await rpc("politics_leave_room",{p_room:roomId});
  leave();
 });
 $("submitVote").onclick=()=>execute(async()=>{
  const c=vote||(state&&state.my_vote);if(!c)throw Error("Elige una opción.");
  state=await rpc("politics_vote",{p_room:roomId,p_choice:c});vote=null;angle=null;render();
 });
 $("sendArgument").onclick=()=>execute(async()=>{
  if(!state||state.phase!=="discussion"||Number(state.count)!==1)throw Error("La conversación individual no está disponible.");
  const argument=$("soloArgument").value.trim();
  if(argument.length<12)throw Error("Escribe un argumento algo más detallado.");
  const seq=soloMessages.filter(x=>x.role==="TÚ").length+1;
  if(seq>5)throw Error("Ya has completado los cinco intercambios de esta ronda. Puedes iniciar otra pregunta.");
  soloMessages.push({role:"TÚ",text:argument});$("soloArgument").value="";renderSoloMessages();
  notice("DILEMA está analizando tu argumento...");
  let response="¿Qué hecho o ejemplo concreto pondría a prueba el argumento que acabas de defender?";
  try{
   const ret=await sb.functions.invoke("politics-moderator",{body:{action:"reply",room_id:roomId,argument,seq}});
   if(ret.error)throw ret.error;
   if(ret.data&&typeof ret.data.reflection==="string"&&typeof ret.data.question==="string"){
    response=ret.data.reflection+" "+ret.data.question;
   }
  }catch(e){console.warn("Diálogo IA no disponible; pregunta de apoyo",String(e&&e.message||e));}
  soloMessages.push({role:"DILEMA",text:response});renderSoloMessages();notice("");
 });
 $("nextTurn").onclick=()=>execute(async()=>{
  if(!state?.can_act)throw Error("Debe pulsarlo quien está en turno.");
  state=await rpc("politics_manage",{p_room:roomId,p_action:"turn"});render();
 });
 document.querySelectorAll("[data-giro]").forEach(b=>b.onclick=()=>execute(async()=>{
  if(!state||state.stage!=="debate"||state.phase!=="discussion"||!state.can_act||state.closing_open)return;
  const kind=b.dataset.giro;
  aura=kind==="contra"?"counter":kind==="ciego"?"blind":"view";
  $("noobsShell").dataset.aura=aura;
  notice("DILEMA está preparando una objeción para todo el grupo...");
  let question=null,mode="CATÁLOGO";
  try{
    const res=await sb.functions.invoke("politics-moderator",{body:{action:"pressure",room_id:roomId,style:kind,summary:$("argumentSummary").value.trim().slice(0,500)}});
    if(res.error)throw res.error;
    if(res.data&&typeof res.data.question==="string"&&res.data.question.length>18){
      question=res.data.question;mode="IA";
    }
  }catch(err){console.warn("IA de repreguntas no disponible",String(err&&err.message||err));}
  if(!question){
    question=kind==="contra"?"¿Cuál sería la objeción más fuerte contra cualquiera de las dos opciones?":
     kind==="ciego"?"¿Quién queda fuera de esta discusión y qué consecuencia soportaría?":
     "Si cambias una condición importante, ¿cuándo dejaría de convencerte la opción elegida?";
  }
  const label=kind==="contra"?"CONTRADÍCEME":kind==="ciego"?"PUNTO CIEGO":"OTRA MIRADA";
  state=await rpc("politics_set_pressure",{p_room:roomId,p_question:(label+": "+question).slice(0,400)});
  angle=null;runFingerprint="";render();
  notice(mode==="IA"?"Nueva pregunta compartida por DILEMA.":"Nueva perspectiva compartida.");
 }));
 $("nextPulse").onclick=()=>nextQuestion(choosePulseTopic());
 $("startDeepDebate").onclick=()=>execute(async()=>{
  if(!state?.host||state.stage!=="pulse"||state.pulse_count<state.pulse_goal)
   throw Error("Hay que completar las seis preguntas del pulso.");
  state=await rpc("politics_start_debate",{p_room:roomId});
  render();setTab("hotpoints");
  notice("Pulso completado. Elegid el tema que queréis debatir primero.");
 });
 $("revote").onclick=()=>nextQuestion(state?.topic||"vivienda");
 $("reveal").onclick=()=>execute(async()=>{
  if(!state?.can_act)throw Error("Solo quien tiene el turno propone cerrar.");
  state=await rpc("politics_propose_close",{p_room:roomId});render();
 });
 async function closeVote(yes){
  await execute(async()=>{
   if(!state?.closing_open)throw Error("La votación de cierre no está abierta.");
   state=await rpc("politics_close_vote",{p_room:roomId,p_accept:yes});
   render();
   if(state.phase==="reveal")notice("La mesa ha decidido terminar. DILEMA dicta sentencia.");
   else if(!state.closing_open)notice("La mesa ha decidido continuar el debate.");
  });
 }
 $("acceptClose").onclick=()=>closeVote(true);
 $("rejectClose").onclick=()=>closeVote(false);
 $("requestSentence").onclick=()=>requestSentence();
 $("anotherTopic").onclick=()=>setTab("hotpoints");
 $("finishRoom").onclick=()=>execute(async()=>{
  if(!confirm("¿Cerrar la sala y eliminar sus votaciones?"))return;
  await rpc("politics_manage",{p_room:roomId,p_action:"delete"});leave();
 });
 $("copySummary").onclick=()=>copy((state&&state.history||[]).map(h=>{
  const n=Number(h.A||0)+Number(h.B||0)+Number(h.N||0),pct=k=>n?Math.round(Number(h[k]||0)*100/n):0;
  return (TOPICS[h.topic]&&TOPICS[h.topic].title||h.topic)+" · Ronda "+h.cycle+": A "+pct("A")+" % / B "+pct("B")+" % / dudas "+pct("N")+" % ("+n+" participantes)";
 }).join("\n")||"Todavía no hay resultados.");
 render();
 const existing=sessionStorage.getItem(KEY);
 if(existing&&/^[\da-f-]{36}$/i.test(existing)){
  try{await auth();roomId=existing;state=await rpc("politics_state",{p_room:roomId});await loadQuestionHistory();render();setTab("debate");}
  catch{roomId=null;state=null;session();render();}
 }
 window.setInterval(refresh,4000);
}
document.addEventListener("DOMContentLoaded",()=>init().catch(e=>notice(String(e&&e.message||e))));
})();