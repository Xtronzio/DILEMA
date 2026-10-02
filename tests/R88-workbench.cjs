const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const {parseHTML}=require('linkedom');
const path=require('path');
const html=fs.readFileSync(process.argv[2]||path.join(__dirname,'..','test-v0.1.16.html'),'utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(x=>x[1]).filter(x=>x.trim());
scripts.forEach(s=>new vm.Script(s));
const ui=scripts.find(s=>s.includes('R88: one workbench'));
assert(ui,'Missing R88 module');
assert.match(html,/pb\.dataset\.ownedRound=String\(currentRoundId\)/);
assert.match(html,/window\.dilemaAssistantAccess=\{round:state\?\.roundId,user:currentUserId,data:access\}/);
const styles=[...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map(x=>x[1]).join('\n');
const fixture=`<style>${styles}</style><main id="debate" class="screen active"><h1 class="debate-title">ABRIMOS EL DEBATE</h1><div id="debatePilotPanel"><div id="pilotPauseBanner" style="display:none">DEBATE PAUSADO</div><button id="pilotSaveSession" style="display:none">GUARDAR Y VOLVER AL HALL</button><div id="pilotTwist" style="display:none">GIRO</div><div id="pilotVoteStage"><div id="pilotInlineRevote" style="display:none">RE-VOTO</div></div><details id="pilotSharedContext" class="context-details"><summary>CONTEXTO DEL DILEMA</summary><div class="context-content">El contexto aprobado sigue siendo consultable.</div></details><button id="pilotContextRequest">SOLICITAR AÑADIR CONTEXTO</button><div id="pilotActionGrid"><button id="pilotProclamaBtn" disabled>📣 PROCLAMAR · 0/1</button><button id="pilotSecretRevoteAction" disabled>CAMBIAR MI VOTO · 0/1</button><button id="pilotGiroBtn">PEDIR GIRO</button><button id="pilotRevoteRequestBtn">PEDIR RE-VOTO</button><button id="pilotAbsentBtn">AUSENTARME</button><button id="pilotPauseAction">SOLICITAR PAUSA</button><button id="pilotEndBtn">FIN DEBATE</button><button id="pilotAbandonBtn">ABANDONAR</button><button id="pilotLimboAction" disabled>PROPONER LIMBO</button></div><div id="pilotAssistantActions"><button id="pilotAssistantOpen" disabled>ASISTENTE · 0/1</button><button id="pilotAssistantRequest">SOLICITAR AYUDA · 0/3</button><button id="pilotAssistantHistory">MIS AYUDAS GUARDADAS · 1/2</button></div><div id="pilotInstructionsRow"><button id="pilotInstructionsBtn">INSTRUCCIONES</button></div><div id="pilotPresence"><div id="pilotHostGroup" style="display:block"><div id="pilotHostBadge">ERES ANFITRIÓN</div><div id="pilotHostRoomCode">CÓDIGO DE DEBATE · TEST</div><button id="pilotAdmissionAction">AÑADIR DEBATIENTE</button></div></div></div></main>`;
(async()=>{
 const {window}=parseHTML('<html><body>'+fixture+'</body></html>');
 const {document}=window,E=id=>document.getElementById(id);
 const storage=new Map(),calls=[],frames=[];
 const c={window:null,document,console,currentRoomMode:'debate',currentRoundId:7,currentUserId:'alice',
  dilemaBoardSnapshot:{round:7,data:{cycle:1,phase:'debate',paused:false,secret_revote_mine:null}},
  dilemaAssistantAccess:{round:7,user:'alice',data:{cycle:1,token:false,approved:false}},
  dilemaLimboSnapshot:{round:7,data:{can_propose:true}},dilemaPresenceView:{my_presence:'present'},
  MutationObserver:window.MutationObserver,requestAnimationFrame:fn=>frames.push(fn),
  getComputedStyle:n=>({display:n.style.display||'block',visibility:n.style.visibility||'visible'}),
  localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},
  renderDebate(){},locked:false,pilotRefresh:async()=>{},r86ActionLocked:id=>c.locked&&id!=='pilotAbandonBtn'&&id!=='pilotAssistantHistory'};
 c.window=c;
 for(const b of document.querySelectorAll('#pilotActionGrid button,#pilotAssistantActions button,#pilotContextRequest,#pilotSaveSession,#pilotInstructionsBtn'))b.onclick=()=>calls.push(b.id);
 const source=E('pilotProclamaBtn');vm.createContext(c);vm.runInContext(ui,c);document.dispatchEvent(new window.Event('DOMContentLoaded'));c.dilemaWorkbenchSync();
 const order=[...E('debatePilotPanel').children].map(n=>n.id);
 for(const [a,b] of [['pilotVoteStage','r88Resources'],['r88Resources','r88Workbench'],['r88Workbench','r88Toolbox'],['r88Toolbox','pilotInstructionsRow'],['pilotInstructionsRow','pilotHostGroup']])assert(order.indexOf(a)<order.indexOf(b),a+' must precede '+b);
 assert(E('r88Empty').hidden===false);assert(E('r88SourceBank').hidden);assert(E('pilotProclamaBtn')===source);
 E('r88Open_action').click();assert.equal(E('r88Drawer').hidden,false);assert(E('r88Drawer_pilotProclamaBtn').disabled);assert(!E('r88Drawer_pilotGiroBtn').disabled);
 E('r88Drawer_pilotGiroBtn').click();assert.equal(E('r88Drawer').hidden,true);assert.deepEqual(calls,['pilotGiroBtn']);
 source.dataset.owned='true';source.dataset.ownedRound='7';source.dataset.ownedUser='alice';source.disabled=false;source.textContent='📣 PROCLAMAR · 1/1';
 c.dilemaBoardSnapshot.data.secret_revote_mine=99;E('pilotSecretRevoteAction').disabled=false;E('pilotSecretRevoteAction').textContent='CAMBIAR MI VOTO · 1/1';
 c.dilemaAssistantAccess.data.token=true;E('pilotAssistantOpen').disabled=false;E('pilotAssistantOpen').textContent='ASISTENTE · 1/1';c.dilemaWorkbenchSync();
 assert.equal([...E('r88ActiveTools').children].filter(b=>!b.hidden).length,3);assert(E('r88Empty').hidden);
 E('r88Open_action').click();assert(E('r88Drawer_pilotProclamaBtn').closest('article').hidden);E('r88DrawerClose').click();E('r88Tool_pilotProclamaBtn').click();assert.equal(calls.at(-1),'pilotProclamaBtn');
 // Limbo is a direct, available tool; Botiquín contains only the potion/pill catalogue.
 E('pilotLimboAction').disabled=false;c.dilemaWorkbenchSync();assert(!E('r88Tool_pilotLimboAction').hidden);
 E('r88Tool_pilotLimboAction').click();assert.equal(calls.at(-1),'pilotLimboAction');
 E('r88Open_medicine').click();assert.equal(E('r88Drawer_pilotLimboAction'),null);assert.equal(E('r88DrawerItems').querySelectorAll('.r88-catalogue').length,6);const content=E('r88DrawerItems').textContent;
 for(const obsolete of ['LA DUDA','EL PRECIO','EN SUS ZAPATOS','LA HUELLA','LA GRIETA'])assert(!content.includes(obsolete));assert(content.includes('CAMBIO TU VOTO'));E('r88DrawerClose').click();
 c.locked=true;for(const id of ['pilotProclamaBtn','pilotSecretRevoteAction','pilotAssistantOpen','pilotLimboAction','pilotContextRequest'])E(id).disabled=true;c.dilemaWorkbenchSync();
 assert(E('r88Tool_pilotSecretRevoteAction').disabled);assert(!E('r88Tool_pilotSecretRevoteAction').hidden);assert(E('r88Tool_pilotLimboAction').hidden);assert(!E('r88GuideHistory').disabled);
 E('r88GuideHistory').click();assert.equal(calls.at(-1),'pilotAssistantHistory');
 source.dataset.owned='false';c.dilemaWorkbenchSync();assert(E('r88Tool_pilotProclamaBtn').hidden);
 E('r88Open_help').click();E('r88IconView').click();assert.equal(E('r88IconView').getAttribute('aria-pressed'),'true');E('r88DrawerClose').click();
 assert(E('r88Workbench').classList.contains('r88-icons'));assert.equal(E('r88Tool_pilotSecretRevoteAction').getAttribute('aria-label'),'CAMBIAR MI VOTO · 1/1');assert.equal(storage.get('dilema_workbench_view:alice'),'icons');
 c.locked=false;c.dilemaBoardSnapshot.data.paused=true;E('pilotSaveSession').disabled=false;c.dilemaWorkbenchSync();E('r88Open_escape').click();assert(!E('r88Drawer_pilotSaveSession').disabled);E('r88Drawer_pilotSaveSession').click();assert.equal(calls.at(-1),'pilotSaveSession');
 c.currentRoundId=8;c.currentUserId='bob';c.dilemaWorkbenchSync();assert([...E('r88ActiveTools').children].every(b=>b.hidden));assert(!E('r88Workbench').classList.contains('r88-icons'));
 // Full-chain serialization and stabilization across intermediate async state updates.
 const second={...c,document:parseHTML('<html><body>'+fixture+'</body></html>').document,currentRoundId:7,currentUserId:'alice',requestAnimationFrame:fn=>frames.push(fn)};
 second.window=second;let release,refreshCalls=0;second.pilotRefresh=async()=>{refreshCalls++;const b=second.document.getElementById('pilotSecretRevoteAction');for(let i=0;i<100;i++){b.disabled=false;b.disabled=true}await new Promise(r=>release=r)};
 vm.createContext(second);vm.runInContext(ui,second);second.dilemaWorkbenchSync();const one=second.pilotRefresh(),two=second.pilotRefresh();assert.equal(one,two);assert.equal(refreshCalls,1);assert(second.document.getElementById('r88Tool_pilotSecretRevoteAction').disabled);
 second.document.getElementById('pilotSecretRevoteAction').disabled=false;release();await one;assert(!second.document.getElementById('r88Tool_pilotSecretRevoteAction').disabled);
 // The observer must settle; unchanged syncs cannot create a continuous repaint loop.
 await Promise.resolve();let processed=0;while(frames.length&&processed<30){frames.shift()();processed++;await Promise.resolve()}
 assert(processed<30,'Workbench observer continuously repaints');
 console.log('R88: ordered frames, source identity, availability/consumption, direct Limbo, private history, drawer dispatch, icon preference, prepared catalogue, session actions, privacy boundaries and refresh serialization passed.');
})().catch(e=>{console.error(e);process.exitCode=1});
