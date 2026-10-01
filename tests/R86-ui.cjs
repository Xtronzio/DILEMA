const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(process.argv[2]||require('path').join(__dirname,'..','test-v0.1.16.html'),'utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(x=>x[1]).filter(x=>x.trim());scripts.forEach(x=>new vm.Script(x));
assert.match(html,/let localPlayerId\s*=/,'The admitted player ID must be writable in the actual app, not just a mock');
assert.match(html,/currentRoomActiveRoundId\?query\.eq\('id',currentRoomActiveRoundId\)/);
assert.match(html,/localStorage\.setItem\('dilema_local_player_id',localPlayerId\)/);
class Button{constructor(id){this.id=id;this.value=false;this.nativeWrites=[];this.style={display:'block'};this.classList={toggle(){}}}get disabled(){return this.value}set disabled(v){this.value=!!v;this.nativeWrites.push(this.value)}}
function node(){return {style:{display:'none'},classList:{contains:()=>false},dataset:{},querySelector:()=>null,querySelectorAll:()=>[],appendChild(){},innerHTML:''}}
const nodes=Object.fromEntries(['debatePilotPanel','pilotVoteStage','pilotSaveSession','r86SessionVote','r86HallSessionVote','r86PausedSessions','r86ChoicePausedSessions'].map(id=>[id,node()]));
const choices=['pilotProclamaBtn','pilotSecretRevoteAction','pilotGiroBtn','pilotRevoteRequestBtn','pilotAbsentBtn','pilotPauseAction','pilotEndBtn','pilotAbandonBtn','pilotContextRequest','pilotLimboAction'].map(id=>new Button(id));
let calls=0,release;
const c={console,HTMLButtonElement:Button,Map,Date,AbortSignal,currentRoomId:1,currentRoomMode:'debate',currentRoomStatus:'playing',currentRoundId:2,currentRoomHostId:'host',localPlayerId:'me',admissionRequestId:null,document:{getElementById:id=>nodes[id]||null,querySelectorAll:s=>s.startsWith('#pilotActionGrid')?choices:[],addEventListener(){},visibilityState:'visible'},getComputedStyle:n=>({display:n.style.display,visibility:'visible'}),renderDebate(){},refreshLobby:async()=>true,pilotRefresh:async()=>{calls++;await new Promise(r=>release=r)},setInterval(){},showScreen(){},alert(){}};
c.window=c;vm.createContext(c);vm.runInContext(scripts.find(s=>s.includes('let sessionView=')),c);
const secret=choices.find(b=>b.id==='pilotSecretRevoteAction'),abandon=choices.find(b=>b.id==='pilotAbandonBtn'),absent=choices.find(b=>b.id==='pilotAbsentBtn');
c.dilemaAdmissionSnapshot={round:2,data:{waiting_votes:1,needs_vote:false,id:null}};
c.dilemaBoardSnapshot={round:2,data:{phase:'debate',paused:false}};
c.r86GuardButtons();
// Emulate all refresh layers repeatedly trying to enable the same controls.
for(let i=0;i<100;i++)secret.disabled=false;
assert(secret.disabled);assert(secret.nativeWrites.every(Boolean),'A disabled private vote change flashes enabled during admission');
abandon.disabled=false;assert(!abandon.disabled);absent.disabled=false;assert(!absent.disabled);
c.dilemaAdmissionSnapshot.data={waiting_votes:0,needs_vote:false,id:null};c.r86GuardButtons();assert(!secret.disabled,'The lock must clear after the first vote');
c.dilemaBoardSnapshot.data={phase:'debate',paused:true};c.r86GuardButtons();assert(secret.disabled);assert(!choices.find(b=>b.id==='pilotEndBtn').disabled);assert(!choices.find(b=>b.id==='pilotPauseAction').disabled);
c.dilemaBoardSnapshot.data={phase:'closing',paused:false};c.r86GuardButtons();assert(secret.disabled);
c.dilemaBoardSnapshot.data={phase:'debate',paused:false};vm.runInContext("sessionRoom=1;sessionView={proposal:{kind:'save'}}",c);c.r86GuardButtons();assert(choices.filter(b=>b.id!=='pilotAbandonBtn').every(b=>b.disabled));
vm.runInContext('sessionView=null',c);c.r86GuardButtons();assert(!secret.disabled);
(async()=>{
 const p=c.pilotRefresh(),p2=c.pilotRefresh();assert.equal(p,p2);assert.equal(calls,1,'Concurrent calls must not overlap wrapper layers');release();await p;
 const p3=c.pilotRefresh();assert.equal(calls,2);release();await p3;
 console.log('R86 UI: actual writable player ID, persisted identity, active original round, 100 stable lock attempts, unlock, pause/closing/session locks and whole-chain serialization passed');
 console.log(scripts.length+' scripts parsed');
})().catch(e=>{console.error(e);process.exitCode=1});
