const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),{parseHTML}=require('linkedom');
const html=fs.readFileSync(process.argv[2]||__dirname+'/test-v0.1.16.html','utf8'),scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(x=>x[1]);
const existing=fs.readFileSync(__dirname+'/R95-workbench.cjs','utf8'),fixture=existing.match(/const fixture=`([\s\S]*?)`;/)[1].replace('${styles}','');
const {document}=parseHTML('<html><body>'+fixture+'</body></html>'),E=id=>document.getElementById(id),storage=new Map(),calls=[];
let state={cycle:1,phase:'debate',paused:false,mine_choice:'A',medicine_state:{inventory:{robo:1,antidoto:1},can_launch:true,targets:[{id:'bob',name:'BOB',limbo:true,positioned:true}],busy:false,server_now:new Date().toISOString()}};
const c={document,window:null,console,currentUserId:'alice',currentRoundId:7,currentRoomMode:'debate',crypto:{randomUUID:()=> 'REQUEST-1'},Date,
 setInterval:()=>1,clearInterval(){},MutationObserver:class{observe(){}},requestAnimationFrame:fn=>fn(),getComputedStyle:e=>({display:e.style.display||'block',visibility:'visible'}),
 localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},r86SessionProposal:()=>null,
 dilemaBoardSnapshot:{round:7,data:state},dilemaPresenceView:{my_presence:'present'},dilemaLimboSnapshot:{round:7,data:{can_propose:false}},
 renderDebate(){},announceHallChange:why=>calls.push(why),pilotRefresh:async()=>{c.dilemaBoardSnapshot={round:7,data:state}},
 sb:{rpc:async(name,args)=>{
  calls.push({name,args});if(name==='launch_debate_medicine'){
   state={...state,medicine_state:{...state.medicine_state,inventory:{robo:0,antidoto:1},busy:true,can_launch:false,pending:{id:'USE-1',incoming:false,outgoing:true,item:'robo',deadline:new Date(Date.now()+20000).toISOString()}}};
  }else if(name==='defend_debate_medicine'){
   state={...state,medicine_state:{...state.medicine_state,inventory:{antidoto:0},busy:false,pending:null,can_launch:true,event:{id:'EVENT-1',item:'senuelo',status:'blocked',result:'Era un señuelo. Has gastado el Antídoto.'}}};
  }else throw Error(name);return {data:{}};
 }}};
c.window=c;vm.createContext(c);
const lock=html.slice(html.indexOf('function r86ActionLocked(id){'),html.indexOf('function r86GuardButtons(){'));
vm.runInContext(lock,c);vm.runInContext(scripts.find(s=>s.includes('R88: one workbench')),c);vm.runInContext(scripts.find(s=>s.includes('R95: potion targeting')),c);
const flush=()=>new Promise(setImmediate);
(async()=>{
 c.dilemaWorkbenchSync();c.dilemaMedicinePaint();
 assert.equal(E('r88Open_escape').textContent.includes('SALIDA'),true);
 assert(!E('r88Tool_pilotMedicine_robo').hidden);assert(!E('r88Tool_pilotMedicine_antidoto').hidden);assert(E('r88Tool_pilotMedicine_espejo').hidden);
 assert(E('r88Tool_pilotMedicine_robo').getAttribute('aria-label').endsWith('1/1'));
 E('r88Tool_pilotMedicine_antidoto').click();assert(E('r95MedicineCopy').textContent.includes('Se usa desde el aviso'));E('r95MedicineChoices').querySelector('button').click();
 E('r88Tool_pilotMedicine_robo').click();assert(E('r95MedicineCopy').textContent.includes('Roba'));assert.equal(E('r95MedicineChoices').querySelectorAll('button').length,2);
 E('r95MedicineChoices').querySelector('button').click();await flush();assert.equal(calls.find(x=>x.name==='launch_debate_medicine').args.p_target,'bob');assert.equal(E('r95MedicineDecision').style.display,'block');assert(c.r86ActionLocked('pilotGiroBtn'));assert(E('r88Tool_pilotMedicine_robo').hidden);
 // Recipient sees generic potion, can defend once; depleted pill disappears and notice needs acknowledgment.
 c.currentUserId='bob';state={...state,medicine_state:{...state.medicine_state,pending:{id:'USE-1',incoming:true,outgoing:false,item:null,deadline:new Date(Date.now()+20000).toISOString()},inventory:{antidoto:1,espejo:0}}};await c.pilotRefresh();
 assert(!E('r95MedicineCopy').textContent.includes('ROBO'));const choices=[...E('r95MedicineChoices').querySelectorAll('button')];assert(choices[0].disabled);assert(!choices[1].disabled);choices[1].click();await flush();assert.equal(calls.find(x=>x.name==='defend_debate_medicine').args.p_defence,'antidoto');assert(E('r88Tool_pilotMedicine_antidoto').hidden);assert(E('r95MedicineCopy').textContent.includes('señuelo'));
 E('r95MedicineChoices').querySelector('button').click();assert.equal(E('r95MedicineDecision').style.display,'none');await c.pilotRefresh();assert.equal(E('r95MedicineDecision').style.display,'none');
 // Neutral hides every owned medicine; action locks dim them during any other proposal.
 state={...state,mine_choice:'N',medicine_state:{inventory:{cambio:1},can_launch:false,targets:[],busy:false}};await c.pilotRefresh();assert(E('r88Tool_pilotMedicine_cambio').hidden);
 state={...state,mine_choice:'A',paused:true};await c.pilotRefresh();assert(!E('r88Tool_pilotMedicine_cambio').hidden);assert(E('r88Tool_pilotMedicine_cambio').disabled);
 E('r88Open_medicine').click();assert.equal(E('r88Drawer_pilotLimboAction'),null);assert(!E('r88DrawerItems').textContent.includes('EN PREPARACIÓN'));assert.equal(E('r88DrawerItems').querySelectorAll('article').length,6);
 console.log('R95 medicine UI: owned inventory, target selection, counts, generic incoming warning, explicit pill defence, serialization, consumption, acknowledged notices, neutral, pause and drawer passed');
})().catch(e=>{console.error(e);process.exitCode=1});
