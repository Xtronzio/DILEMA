const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(process.argv[2]||require('path').join(__dirname,'..','test-v0.1.16.html'),'utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(x=>x[1]).filter(x=>x.trim());
scripts.forEach(x=>new vm.Script(x));
const eventScript=scripts.find(s=>s.includes('let lastEventId='));
const limboScript=scripts.find(s=>s.includes('/* R80: limbo decisions'));
function element(){return {style:{display:'none'},dataset:{},textContent:'',children:[],classList:{contains:()=>false,toggle(){},add(){},remove(){}},appendChild(n){this.children.push(n)},replaceChildren(){this.children=[]},querySelector(){return null},querySelectorAll(){return []},addEventListener(){}}}
const storage=new Map();
function eventHarness(){
 const nodes={debate:element(),debatePilotPanel:element(),pilotEvent:element()};
 const db={debate_events:[],debate_private_proclamations:[]};const timers=[];let delay=null;
 const c={console,currentRoomMode:'debate',currentRoundId:1,currentUserId:'me',setInterval(){},setTimeout(fn){timers.push(fn)},sessionStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v)},document:{getElementById:k=>nodes[k]||null,addEventListener(){},createElement:element},sb:{rpc:async()=>({data:{}}),from(table){let round,min;const q={select(){return q},eq(k,v){round=v;return q},gt(k,v){min=v;return q},order(){return q},limit(){return q},then(resolve,reject){const data=db[table].filter(x=>x.round_id===round&&x.id>min);return (delay||Promise.resolve()).then(()=>({data})).then(resolve,reject)}};return q}}};
 c.window=c;vm.createContext(c);vm.runInContext(eventScript.replace(/\}\)\(\);\s*$/, 'window.testEvents={latestEvent,init};})();'),c);
 c.pilotRefresh=()=>c.testEvents.latestEvent();
 return {c,nodes,db,timers,setDelay:p=>{delay=p},ack(){const b=nodes.pilotEvent.children.find(x=>x.textContent==='ENTENDIDO');assert(b,'Dismiss button expected');b.onclick()},text:()=>nodes.pilotEvent.children[0]?.textContent};
}
async function eventTests(){
 const h=eventHarness();h.db.debate_events.push({id:100,round_id:1,event_type:'proclamation',text:'PUBLIC'});h.db.debate_private_proclamations.push({id:2,round_id:1,text:'PRIVATE',reply_enabled:false});
 await h.c.testEvents.latestEvent();assert.equal(h.text(),'PRIVATE');h.ack();assert.equal(h.text(),'PUBLIC');h.ack();
 await h.c.pilotRequestTwist();assert.equal(h.nodes.pilotEvent.style.display,'none','First giro replays old notices');
 h.db.debate_private_proclamations.push({id:3,round_id:1,text:'NEW PRIVATE',reply_enabled:false});h.db.debate_events.push({id:101,round_id:1,event_type:'proclamation',text:'NEW PUBLIC'});
 await h.c.testEvents.latestEvent();assert.equal(h.text(),'NEW PRIVATE','Public cursor hides lower private IDs');h.ack();assert.equal(h.text(),'NEW PUBLIC');h.ack();
 const reload=eventHarness();Object.assign(reload.db,h.db);await reload.c.testEvents.latestEvent();assert.equal(reload.nodes.pilotEvent.style.display,'none','Acknowledged notices replay after reload');
 h.db.debate_events.push({id:102,round_id:1,event_type:'system',text:'OLD TIMER'});await h.c.testEvents.latestEvent();const oldTimer=h.timers.at(-1);
 h.c.currentRoundId=2;h.db.debate_events.push({id:1,round_id:2,event_type:'proclamation',text:'NEW ROUND'});await h.c.testEvents.latestEvent();oldTimer();assert.equal(h.text(),'NEW ROUND');assert.equal(h.nodes.pilotEvent.style.display,'block');h.ack();
 let release;h.setDelay(new Promise(r=>release=r));h.db.debate_events.push({id:2,round_id:2,event_type:'proclamation',text:'STALE REQUEST'});
 const stale=h.c.testEvents.latestEvent();h.c.currentRoundId=3;release();await stale;assert.equal(h.nodes.pilotEvent.style.display,'none','Stale response entered a new round');
 console.log('Events: first giro, independent cursors, acknowledgements, reload, new round and stale responses passed');
}
function limboTests(){
 let now=Date.now();class Clock extends Date{static now(){return now}}
 const nodes={};for(const id of ['debate','pilotActionGrid','pilotVoteStage','pilotLimboAction','pilotLimboVoteBox','pilotLimboStatus','pilotLimboTimer','pilotLimboReturnHint','pilotAbsentBtn','pilotLimboModal','pilotLimboTarget','pilotLimboAccept','pilotLimboCancel','pilotLimboDurations'])nodes[id]=element();
 nodes.debate.classList.contains=x=>x==='active';nodes.pilotLimboDurations.querySelectorAll=()=>[];
 const question=element(),count=element(),actions=element(),yes=element(),no=element();yes.dataset.limboVote='YES';no.dataset.limboVote='NO';
 nodes.pilotLimboVoteBox.querySelector=s=>({'[data-limbo-question]':question,'.limbo-count':count,'.limbo-actions':actions})[s];nodes.pilotLimboVoteBox.querySelectorAll=()=>[yes,no];
 const c={console,Date:Clock,currentRoundId:1,localPlayerId:'self',paused:false,setInterval(){},getComputedStyle:n=>({display:n.style.display}),document:{getElementById:k=>nodes[k]||null,querySelectorAll:()=>[]},pilotRefresh:async()=>{},pilotToggleAbsent:async()=>{},sb:{rpc:async()=>({data:{}})}};c.window=c;vm.createContext(c);
 vm.runInContext(limboScript.replace(/\}\)\(\);\s*$/, 'window.testLimbo={paint,tick};})();'),c);
 const state={server_now:new Date(now).toISOString(),present:true,paused:false,phase:'debate',targets:[{id:'other'}],can_propose:true,blocked:false,proposal:{id:1,name:'YOU',duration:180,proposer_me:false,target_me:true,can_vote:false,yes:1,no:0,players:2,mine:null}};
 c.dilemaLimboSnapshot={round:1,data:state};c.testLimbo.paint();assert.equal(actions.style.display,'none');assert(yes.disabled&&no.disabled);assert(question.textContent.includes('Tú no participas'));assert(count.textContent.includes('1 / 2'));
 state.proposal.target_me=false;state.proposal.can_vote=true;c.testLimbo.paint();assert.equal(actions.style.display,'grid');assert(!yes.disabled);
 state.proposal=null;state.can_propose=false;c.testLimbo.paint();assert(nodes.pilotLimboAction.disabled,'Two-player limbo enabled');
 state.blocked=true;state.until_at=new Date(now+180000).toISOString();state.present=false;c.testLimbo.paint();
 const b=nodes.pilotAbsentBtn,disabledWrites=[],labelWrites=[];let disabled=b.disabled,label=b.textContent;
 Object.defineProperty(b,'disabled',{get:()=>disabled,set:v=>{disabledWrites.push(v);disabled=v}});Object.defineProperty(b,'textContent',{get:()=>label,set:v=>{labelWrites.push(v);label=v}});
 const presenceScript=scripts.find(s=>s.includes('const requestBox=E("pilotPresenceRequestBox"),absenceButton'));
 const block=presenceScript.slice(presenceScript.indexOf('     const requestBox=E("pilotPresenceRequestBox"),absenceButton'),presenceScript.indexOf('     const giroButton=E("pilotGiroBtn")'));
 c.E=id=>nodes[id]||null;c.pr={my_presence:'absent'};
 for(let i=0;i<12;i++){now+=1000;vm.runInContext('{'+block+'}',c);c.testLimbo.tick();c.testLimbo.paint()}
 assert(disabledWrites.every(x=>x===true),'Refresh briefly enables limbo return');assert.equal(labelWrites.length,0,'Refresh flickers return text');assert.equal(b.textContent,'VOLVER BLOQUEADO');
 now+=180000;c.testLimbo.tick();assert.equal(b.textContent,'SOLICITAR VOLVER');assert.equal(b.disabled,false);
 console.log('Limbo UI: target exclusion, eligible buttons, two-player guard, stable blocked return and expiry passed');
}
(async()=>{await eventTests();limboTests();console.log(scripts.length+' scripts parsed; R84 UI checks passed')})().catch(e=>{console.error(e);process.exit(1)});
