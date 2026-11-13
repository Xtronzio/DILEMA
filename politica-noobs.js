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
let soloMessages=[],soloRound=null;
const session=()=>roomId?sessionStorage.setItem(KEY,roomId):sessionStorage.removeItem(KEY);
function notice(s){$("notice").textContent=s||"";}
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
 const t=TOPICS[id],used=new Set((prior||[]).map(x=>String(x.question||"").trim().toLowerCase()));
 const available=t.q.filter(x=>!used.has(x[0].toLowerCase()));
 if(!available.length)throw Error("Ya hemos debatido todas las preguntas de este Hot Point. Elige otro tema.");
 const item=available[rand(available.length)];
 if(rand(2)===0)return {question:item[0],a:item[1],b:item[2],twist:item[3]};
 return {question:item[0],a:item[2],b:item[1],twist:item[3]};
}
async function nextQuestion(id){
 await execute(async()=>{
  if(!roomId||!state||!state.host)throw Error("Solo el anfitrión puede abrir la ronda.");
  if(["lobby","discussion","reveal"].indexOf(state.phase)<0)throw Error("La ronda actual sigue en votación.");
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
  state=result;vote=null;angle=null;runFingerprint="";soloMessages=[];soloRound=null;
  render();setTab("debate");
  notice(mode==="IA"?"Nueva pregunta generada por DILEMA. Todos deben votar.":"Nueva pregunta del catálogo. Todos deben votar.");
 });
}
function setTab(name){
 document.querySelectorAll("[data-tab]").forEach(x=>x.setAttribute("aria-selected",String(x.dataset.tab===name)));
 ["hotpoints","debate","mapa"].forEach(x=>$(x).hidden=x!==name);
 if(name==="mapa")renderMap();
}
function renderHotpoints(){
 const root=$("hotpointCards");root.replaceChildren();
 Object.entries(TOPICS).forEach(pair=>{
  const id=pair[0],t=pair[1],card=el("article","card");
  card.append(el("h3","",t.title),el("p","small muted",t.teaser));
  const b=el("button","btn small","INICIAR OTRA RONDA");
  if(!state||!state.host)b.disabled=true;
  b.onclick=()=>nextQuestion(id);
  card.append(b);root.append(card);
 });
}
function renderRoom(){
 $("roomSetup").hidden=!!state;
 $("roomInfo").hidden=!state;
 if(!state)return;
 $("roomCode").textContent=state.code;
 const phases={lobby:"SALA PREPARADA",voting:"VOTACIÓN",discussion:"DEBATE",reveal:"SIGLAS REVELADAS"};
 $("roomStatus").textContent=state.count+" de "+state.expected+" participantes · "+(phases[state.phase]||state.phase);
 const root=$("members");root.replaceChildren();
 (state.participants||[]).forEach((m,i)=>root.append(el("span","person",(state.phase==="discussion"&&i===state.turn?"🎤 ":"")+m.name+(m.host?" · ANFITRIÓN":""))));
}
function renderDebate(){
 const active=!!state,phase=state&&state.phase;
 $("phaseTitle").textContent=active?(TOPICS[state.topic]&&TOPICS[state.topic].title||"DEBATE"):"Debate compartido";
 $("ballotBlock").hidden=phase!=="voting";
 $("discussionBlock").hidden=phase!=="discussion";
 $("revealBlock").hidden=phase!=="reveal";
 $("hostControls").hidden=!state||!state.host;
 $("another").hidden=!state||!state.host;
 $("nextTurn").hidden=!state||!state.host||Number(state.count)===1;
 $("soloDialogue").hidden=!(phase==="discussion"&&Number(state.count)===1);
 $("groupSummary").hidden=!(phase==="discussion"&&Number(state.count)>1&&state.host);
 if(phase==="discussion"&&Number(state.count)===1){
  if(soloRound!==state.cycle){soloRound=state.cycle;soloMessages=[];$("soloArgument").value="";}
  renderSoloMessages();
 }
 document.querySelectorAll("[data-giro]").forEach(b=>b.disabled=!state||!state.host||phase!=="discussion");
 if(!active){$("phaseDetail").textContent="Crea una sala o únete con su código para comenzar.";return;}
 if(phase==="lobby"){$("phaseDetail").textContent="El anfitrión abre un Hot Point. Después todos votáis, debatís y pasáis a otra pregunta.";return;}
 if(phase==="voting"){
  $("phaseDetail").textContent="Han votado "+state.voted+" de "+state.count+". Los resultados se ocultan hasta que terminen todos.";
  $("voteContext").textContent="VOTACIÓN "+state.cycle+" · SIN SIGLAS";
  $("voteQuestion").textContent=state.question;
  $("twistText").textContent=state.cycle>1?(state.twist||"Nueva situación para debatir."):"Elige la postura que quieres defender.";
  const root=$("voteChoices");root.replaceChildren();
  [["A",state.A],["B",state.B],["N","DEPENDE / NECESITO MÁS INFORMACIÓN"]].forEach(pair=>{
   const val=pair[0],lab=el("label","choice"),r=el("input");
   r.type="radio";r.name="voto";r.value=val;r.checked=(vote||state.my_vote)===val;
   r.onchange=()=>{vote=val;$("submitVote").disabled=false;};
   lab.append(r,el("span","",pair[1]));root.append(lab);
  });
  $("submitVote").disabled=!(vote||state.my_vote);
  $("submitVote").textContent=state.my_vote?"CAMBIAR MI VOTO":"VOTAR";
 }
 if(phase==="discussion"){
  $("phaseDetail").textContent="Cada persona defiende su postura por turnos. Después podéis abrir otra pregunta y votar de nuevo.";
  const count=Number(state.count)||1,t=state.tally||{A:0,B:0,N:0},out=$("voteResults");out.replaceChildren();
  [["A",state.A],["B",state.B],["N","Depende / no lo sé"]].forEach(pair=>{
   const n=Number(t[pair[0]]||0),pct=count?Math.round(100*n/count):0,row=el("div","result");
   row.append(el("b","",pair[0]+" · "+pct+" % · "+n+" voto"+(n===1?"":"s")),el("p","",pair[1]));out.append(row);
  });
  $("speaker").textContent=(state.participants[state.turn]||{}).name||"Participante";
  $("moderatorQuestion").textContent=angle||state.twist||"¿Qué argumento te haría revisar tu respuesta?";
 }
 if(phase==="reveal"){
  $("phaseDetail").textContent="Al cerrar el Hot Point aparecen las propuestas oficiales que hemos podido verificar.";
  renderSources();
 }
}
function renderSources(){
 const root=$("partySources");root.replaceChildren();
 const refs=EVIDENCE[state.topic]||[];
 PARTIES.forEach(p=>{
  const item=el("div","result"),e=refs.find(x=>x.p===p);
  item.append(el("b","",p),el("div","label",e?e.type:"PROPUESTAS PENDIENTES DE VERIFICAR"));
  item.append(el("p","",e?e.t:"Aún no hay documentos electorales de 2026 contrastados para este Hot Point. No se atribuye una posición."));
  if(e){
   if(e.page)item.append(el("div","fine","Páginas del documento: "+e.page));
   const a=el("a","","CONSULTAR FUENTE OFICIAL");a.href=e.url;a.target="_blank";a.rel="noopener noreferrer";item.append(a);
  }
  root.append(item);
 });
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
function render(){renderRoom();renderHotpoints();renderDebate();renderMap();}
async function refresh(){
 if(!roomId||working)return;
 try{
  const s=await rpc("politics_state",{p_room:roomId}),was=state&&state.cycle,phase=state&&state.phase;
  state=s;
  const fp=JSON.stringify([s.cycle,s.phase,s.voted,s.count,s.turn,s.my_vote,s.topic,s.twist]);
  if(fp!==runFingerprint){
   runFingerprint=fp;if(was!==s.cycle||phase!==s.phase){vote=null;angle=null;}render();
  }
 }catch(e){notice("No se pudo actualizar la sala: "+String(e&&e.message||"error"));}
}
function leave(){
 roomId=null;state=null;session();history.replaceState(null,"",location.pathname);
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
 document.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
 $("create").onclick=()=>execute(async()=>{
  if(!$("consent").checked)throw Error("Marca el consentimiento de participación para continuar.");
  await auth();const r=await rpc("politics_new_room_safe",{p_name:$("alias").value.trim(),p_expected:Number($("participantsExpected").value),p_consent:true});
  roomId=r.room_id;session();state=await rpc("politics_state",{p_room:roomId});render();setTab("hotpoints");
 });
 $("join").onclick=()=>execute(async()=>{
  if(!$("consent").checked)throw Error("Marca el consentimiento de participación para continuar.");
  await auth();const r=await rpc("politics_join_room_safe",{p_code:$("roomJoin").value.trim().toUpperCase(),p_name:$("alias").value.trim(),p_consent:true});
  roomId=r.room_id;session();state=await rpc("politics_state",{p_room:roomId});render();setTab("debate");
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
 $("nextTurn").onclick=()=>execute(async()=>{state=await rpc("politics_manage",{p_room:roomId,p_action:"turn"});render();});
 document.querySelectorAll("[data-giro]").forEach(b=>b.onclick=()=>execute(async()=>{
  if(!state||state.phase!=="discussion"||!state.host)return;
  const kind=b.dataset.giro;
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
  state=await rpc("politics_set_pressure",{p_room:roomId,p_question:question});
  angle=null;runFingerprint="";render();
  notice(mode==="IA"?"Nueva pregunta compartida por DILEMA.":"Nueva perspectiva compartida.");
 }));
 $("revote").textContent="SIGUIENTE PREGUNTA · NUEVA VOTACIÓN";
 $("revote").onclick=()=>nextQuestion(state&&state.topic||"vivienda");
 $("reveal").onclick=()=>execute(async()=>{
  state=await rpc("politics_manage",{p_room:roomId,p_action:"reveal"});render();
 });
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
  try{await auth();roomId=existing;state=await rpc("politics_state",{p_room:roomId});render();}
  catch{roomId=null;state=null;session();render();}
 }
 window.setInterval(refresh,4000);
}
document.addEventListener("DOMContentLoaded",()=>init().catch(e=>notice(String(e&&e.message||e))));
})();