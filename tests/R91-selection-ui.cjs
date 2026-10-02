const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),path=require('path');
const {parseHTML}=require('linkedom');
const html=fs.readFileSync(process.argv[2]||path.join(__dirname,'..','test-v0.1.16.html'),'utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(m=>m[1]);scripts.forEach(s=>new vm.Script(s));
const {document}=parseHTML(html),E=id=>document.getElementById(id),calls=[],screens=[],alerts=[];
const context=document.createElement('details');context.id='proposalContext';E('dilemmaProposal').appendChild(context);
let proposal={id:1,status:'open',question:'FIRST',option_a:'A',option_b:'B',yes:0,no:0,total:3,has_voted:false},room={status:'waiting'},error=null;
const c={document,console,currentRoomId:7,currentRoomMode:'debate',currentRoomStatus:'waiting',currentRoomHostId:'one',localPlayerId:'one',proposalRefreshRun:0,
 currentDebateSelection:{phase:'random',total:3,voted:3},selectionAudienceChosen:true,
 sb:{rpc:async(name,args)=>{calls.push(name);return {data:proposal,error:name==='debate_vote_proposal'?error:null}}},
 getRoom:async()=>{calls.push('getRoom');return room},refreshDebateSelection:async()=>{calls.push('selection');return false},
 subscribeToRounds:()=>calls.push('subscribe'),startGameRefresh:()=>calls.push('startRefresh'),refreshGame:async()=>{calls.push('game');c.showScreen('voting')},reloadHall:()=>calls.push('hall'),announceHallChange:()=>calls.push('broadcast'),alert:s=>alerts.push(s),
 renderDilemmaCopy:(e,s)=>e.textContent=s,renderContextText:(e,s)=>e.textContent=s,renderSelectionFilters(){},
 showScreen:id=>{document.querySelectorAll('.screen').forEach(s=>s.classList.remove('active'));E(id)?.classList.add('active');screens.push(id)}
};
vm.createContext(c);
vm.runInContext('let currentDilemmaProposal=null,rejectedDilemmaIds=[];'+html.slice(html.indexOf('async function refreshDilemmaProposal(){'),html.indexOf('async function startApprovedDilemma(){')),c);
vm.runInContext(html.slice(html.indexOf('function renderDebateSelection(){'),html.indexOf('function chooseSelectionAudience(){')),c);
(async()=>{
 c.renderDebateSelection();assert.equal(E('selectionDraw').style.display,'none');assert.equal(E('selectionRandomWaiting').textContent,'PREPARANDO DILEMA…');assert.equal(E('selectionHostBadge').style.display,'block');
 c.localPlayerId='two';c.renderDebateSelection();assert.equal(E('selectionDraw').style.display,'none');assert.equal(E('selectionRandomWaiting').style.display,'block');assert.equal(E('selectionHostBadge').style.display,'none');
 c.localPlayerId='one';await c.refreshDilemmaProposal();assert.equal(E('proposalQuestion').textContent,'FIRST');assert.equal(E('proposalLaunch').style.display,'none');
 // Replacement goes straight into the same proposal screen; no hall or filters.
 calls.length=0;screens.length=0;proposal={...proposal,id:2,question:'REPLACEMENT'};
 await c.voteDilemmaProposal(false);assert.deepEqual(screens,['dilemmaProposal']);assert(!calls.includes('selection'));assert(!calls.includes('hall'));assert.equal(E('proposalQuestion').textContent,'REPLACEMENT');assert([...document.querySelectorAll('#proposalVote button')].every(b=>!b.disabled&&!b.classList.contains('is-selected')));
 // Accepted state is only transitional; no extra host action is displayed.
 proposal={...proposal,status:'accepted',has_voted:true};await c.refreshDilemmaProposal();assert.equal(E('proposalLaunch').style.display,'none');assert.equal(E('proposalPending').textContent,'ABRIENDO VOTACIÓN…');
 // A late ballot informs the user and directly adopts server-side posture voting.
 calls.length=0;screens.length=0;proposal=null;room={status:'playing'};error={message:'Votación cerrada'};
 await c.voteDilemmaProposal(true);assert.equal(alerts.at(-1),'HAS LLEGADO TARDE. LA MESA YA HA DECIDIDO.');assert.deepEqual(screens,['voting']);assert(!calls.includes('selection'));assert(!calls.includes('hall'));assert.equal(c.currentRoomStatus,'playing');assert.equal(c.currentDebateSelection,null);
 // A response for an old room cannot redirect the new room's screen.
 c.currentRoomStatus='waiting';c.currentRoomId=7;screens.length=0;let release;
 c.sb.rpc=()=>new Promise(r=>release=r);const pending=c.refreshDilemmaProposal();c.currentRoomId=8;release({data:{id:3,status:'open',question:'STALE'}});await pending;assert.equal(screens.length,0);
 console.log('R91 UI: automatic random preparation, direct replacement, no intermediate launch, late-vote notice, direct voting and stale response protection passed');
})().catch(e=>{console.error(e);process.exitCode=1});
