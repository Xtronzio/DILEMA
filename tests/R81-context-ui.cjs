const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(process.argv[2]||process.env.DILEMA_HTML||'test-v0.1.16.html','utf8');
let scripts=0;for(const [,a,s] of html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)){if(!a.includes('src=')){new vm.Script(s);scripts++}}
const source=html.slice(html.indexOf("let debateContextView="),html.indexOf('const previousContextPilotRefresh='));
const nodes=new Map();
function node(id){if(nodes.has(id))return nodes.get(id);const classes=new Set();const n={id,style:{display:'none'},dataset:{},value:'',textContent:'',disabled:false,classList:{add:c=>classes.add(c),toggle:(c,on)=>on?classes.add(c):classes.delete(c),contains:c=>classes.has(c)},querySelectorAll:()=>[],appendChild(){},insertAdjacentElement(){}};nodes.set(id,n);return n}
for(const id of ['debatePilotPanel','pilotVoteStage','pilotSharedContext','pilotContextDecision','pilotContextRequest','pilotContextProposed','pilotContextMessage','pilotContextProgress','pilotContextVotes','pilotContextWrite','pilotContextActions','pilotContextPublish','pilotContextCancel','pilotContextText','pilotContextError','pilotVoteLate'])node(id);
const yes=node('yes'),no=node('no');yes.dataset.contextVote='yes';no.dataset.contextVote='no';node('pilotContextDecision').querySelectorAll=()=>[yes,no];
const action=node('pilotGiroAction'),calls=[],timeouts=[];
const context={document:{getElementById:id=>nodes.get(id)||null,querySelectorAll:()=>[action]},window:{dilemaAssistantState:{active:true},pilotRefresh:async()=>{},syncCharacterCounters(){}},currentRoundId:81,renderContextText:(n,text)=>{n.textContent=text},getComputedStyle:n=>n.style,sb:{rpc:async(name,args)=>{calls.push({name,args});return {error:null}}},console,alert(){},setTimeout:f=>{timeouts.push(f);return timeouts.length},clearTimeout(){}};
vm.createContext(context);vm.runInContext(source,context);
function paint(view){context.nextView=view;vm.runInContext('debateContextView=nextView;paintDebateContext()',context)}
const base={id:1,status:'open',context:'APPROVED CONTEXT',players:3,voted:1,mine:null,requester_me:false,last_id:1,last_status:'open'};
(async()=>{
 paint(base);assert.equal(yes.disabled,false);assert.equal(no.disabled,false);assert.equal(yes.classList.contains('selected'),false);assert.equal(node('pilotContextWrite').style.display,'none');assert.equal(action.disabled,true);
 paint({...base,status:'approved',requester_me:true,last_status:'approved'});assert.equal(node('pilotContextVotes').style.display,'none');assert.equal(node('pilotContextWrite').style.display,'block');assert.equal(node('pilotContextPublish').style.display,'block');
 const draft='<img src=x onerror=alert(1)> CONTEXTO PENDIENTE';
 paint({...base,status:'review',proposed_text:draft,last_status:'review'});assert.equal(node('pilotContextProposed').textContent,draft);assert.equal(node('pilotSharedContext').textContent,'APPROVED CONTEXT');assert.equal(node('pilotContextVotes').style.display,'grid');assert.equal(node('pilotContextWrite').style.display,'none');assert.equal(node('pilotContextRequest').disabled,true);
 await vm.runInContext("contextAction('vote',true)",context);assert.equal(calls.at(-1).name,'debate_review_context');
 paint({...base,status:'review',mine:true,requester_me:true,proposed_text:draft,last_status:'review'});assert.equal(yes.disabled,true);assert.equal(yes.classList.contains('selected'),true);assert.equal(no.classList.contains('selected'),false);
 paint({...base,id:null,status:'published',context:'APPROVED CONTEXT\n\nNEW TEXT',count:1,last_status:'published'});assert.equal(node('pilotContextDecision').style.display,'none');assert.equal(node('pilotVoteLate').style.display,'block');assert.ok(node('pilotVoteLate').textContent.includes('CONTEXTO APROBADO'));const timerCount=timeouts.length;
 vm.runInContext('paintDebateContext()',context);assert.equal(timeouts.length,timerCount,'Polling must not restart outcome banner');
 paint({...base,id:2,last_id:2});await vm.runInContext("contextAction('vote',false)",context);assert.equal(calls.at(-1).name,'debate_vote_context');
 assert.ok(html.includes('source+":"+access.context_signature'));assert.ok(html.includes('data.context_signature'));assert.ok(html.includes('segunda votación por mayoría'));
 console.log(`PASS R81: ${scripts} inline scripts parse; independent voting UI, plain-text draft, action locks, automatic YES, stage-specific RPCs, stable outcome banner and context cache keys`);
})();
