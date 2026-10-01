const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(process.env.DILEMA_HTML || 'test-v0.1.16.html','utf8');
let count=0;for(const [,attributes,source]of html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)){if(attributes.includes('src='))continue;new vm.Script(source);count++}
const source=html.slice(html.indexOf('/* R80: limbo decisions'),html.indexOf('</script>',html.indexOf('/* R80: limbo decisions')));
const nodes=new Map();function node(id){if(nodes.has(id))return nodes.get(id);const n={id,textContent:'',value:'',disabled:false,style:{display:'none'},classList:{contains:c=>id==='debate'&&c==='active',add(){},remove(){},toggle(){}},focus(){},addEventListener(){},querySelector(){},querySelectorAll(){return[]}};nodes.set(id,n);return n}
for(const id of ['pilotLimboAction','pilotLimboVoteBox','pilotLimboStatus','pilotVoteStage','pilotActionGrid','pilotAbsentBtn','pilotLimboTimer','pilotLimboReturnHint','pilotLimboTarget','pilotLimboAccept','pilotLimboCancel','pilotLimboError','pilotLimboModal','pilotLimboDurations'])node(id);
const question=node('question'),countNode=node('count'),actions=node('actions'),yes=node('yes'),no=node('no');yes.dataset={limboVote:'YES'};no.dataset={limboVote:'NO'};
node('pilotLimboVoteBox').querySelector=s=>s==='[data-limbo-question]'?question:s==='.limbo-count'?countNode:actions;
node('pilotLimboVoteBox').querySelectorAll=()=>[yes,no];
let clock=Date.now(),timer,previousCalls=0;
class Clock extends Date{static now(){return clock}}
const s={server_now:new Date(clock).toISOString(),phase:'debate',present:true,paused:false,targets:[{id:'other',name:'OTHER'}],blocked:false,proposal:null};
const context={document:{getElementById:id=>nodes.get(id)||null,querySelectorAll:()=>[node('pilotLimboAction'),node('pilotAbsentBtn')]},getComputedStyle:n=>n.style,window:{dilemaLimboSnapshot:{round:1,data:s},pilotRefresh:async()=>{previousCalls++},pilotToggleAbsent:async()=>{}},currentRoundId:1,Date:Clock,setInterval:fn=>{timer=fn},console};
context.document.getElementById=(id)=>id==='debate'?node('debate'):nodes.get(id)||null;
vm.createContext(context);vm.runInContext(source,context);
(async()=>{
 await context.window.pilotRefresh();assert.equal(node('pilotLimboAction').disabled,false);
 s.proposal={id:1,name:'OTHER',duration:180,proposer_me:false,yes:1,no:0,players:3,mine:null};await context.window.pilotRefresh();assert.equal(node('pilotAbsentBtn').disabled,true);assert.equal(node('pilotLimboVoteBox').style.display,'block');assert.ok(question.textContent.includes('3 MINUTOS'));assert.equal(yes.disabled,false);
 s.proposal=null;s.present=false;s.blocked=true;s.until_end=false;s.until_at=new Date(clock+180000).toISOString();await context.window.pilotRefresh();assert.equal(node('pilotAbsentBtn').disabled,true);assert.equal(node('pilotLimboTimer').textContent,'3:00');
 clock+=180001;timer();assert.equal(node('pilotAbsentBtn').disabled,false);assert.equal(node('pilotAbsentBtn').textContent,'SOLICITAR VOLVER');
 s.until_end=true;timer();assert.equal(node('pilotAbsentBtn').disabled,true);assert.equal(node('pilotLimboTimer').textContent,'HASTA FIN DEBATE');
 assert.ok(previousCalls>0);console.log(`PASS: ${count} inline scripts parse; shared vote box, action locks, countdown, expiry and until-end UI`);
})();
