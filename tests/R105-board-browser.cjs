const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm'),{chromium}=require('playwright');
const html=fs.readFileSync(process.argv[2]||__dirname+'/../test-v0.1.16.html','utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(m=>m[1]);
scripts.filter(s=>s.trim()).forEach(s=>new vm.Script(s));
const sessions=scripts.find(s=>s.includes('R86: preserve sessions')).split('/* Serialize the full chain')[0];
const drawers=scripts.find(s=>s.includes('function dispatch(action)')&&s.includes('r88SourceBank'));
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.DILEMA_CHROMIUM_EXECUTABLE?{executablePath:process.env.DILEMA_CHROMIUM_EXECUTABLE,args:['--no-sandbox','--disable-gpu','--disable-dev-shm-usage']}:{})});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setContent([...html.matchAll(/<style\b[^>]*>[\s\S]*?<\/style>/gi)].map(m=>m[0]).join('\n')+'<main id="room"></main><main id="debateChoice"></main><main id="debate" class="screen active"><section id="debatePilotPanel"><div id="pilotPauseBanner">DEBATE PAUSADO</div><div id="pilotVoteStage"></div><div id="pilotActionGrid"></div><div id="pilotAssistantActions"></div></section></main>');
  await page.evaluate(()=>{
   Object.assign(window,{currentRoomId:101,currentRoundId:202,currentRoomMode:'debate',currentRoomStatus:'playing',currentRoomHostId:'host',currentRoomActiveRoundId:202,currentUserId:'guest',localPlayerId:'guest',currentRoundStatus:'debate',currentDilemma:{},localVoteChoice:'B',hallReloading:false,calls:[],hallReturns:0});
   window.dilemaPresenceView={my_presence:'present'};window.dilemaBoardSnapshot={round:202,data:{phase:'debate',paused:true,mine_choice:'B',cycle:1,medicine_state:{busy:false,inventory:{},can_launch:false}}};
   window.pilotRefresh=async()=>{};window.renderDebate=()=>{};window.saveRoomSession=()=>{};window.reloadHall=()=>hallReturns++;window.announceHallChange=()=>{};window.refreshLobby=async()=>{};window.showScreen=()=>{};
   window.sb={rpc(name,args){calls.push({name,args});return {abortSignal:async()=>({data:args.p_action==='save'?{room_status:'playing',sessions:[],proposal:{id:303,kind:'save',yes:1,no:0,players:3,mine:true,can_vote:true}}:{room_status:'waiting',active_round_id:null,sessions:[{id:404,round_id:202,question:'Dilema guardado'}],proposal:null}})}}};
  });
  await page.addScriptTag({content:sessions});await page.addScriptTag({content:drawers});
  await page.evaluate(()=>{paintSessions();dilemaWorkbenchSync()});
  await page.locator('#r88Open_escape').click();
  assert.equal(await page.locator('#r88Drawer_pilotSaveSession').isEnabled(),true,'Paused save must be enabled');
  assert.equal(await page.locator('#r88Status_pilotSaveSession').textContent(),'DISPONIBLE');
  await page.locator('#r88Drawer_pilotSaveSession').click();await page.waitForTimeout(80);
  assert.equal(await page.evaluate(()=>calls[0].args.p_action),'save');
  assert.equal(await page.locator('#r86SessionVote').isVisible(),true);
  assert.match(await page.locator('#r86SessionVote .session-count').textContent(),/1 \/ 3.*MAYORÍA/);
  assert.equal(await page.locator('#r86SessionVote [data-session-vote="yes"]').isEnabled(),false,'Proposer has already voted');
  await page.evaluate(()=>{sessionView.proposal.mine=null;sessionView.proposal.can_vote=true;paintSessions()});
  await page.locator('#r86SessionVote [data-session-vote="yes"]').click();await page.waitForTimeout(80);
  assert.equal(await page.evaluate(()=>calls[1].args.p_vote),true);assert.equal(await page.evaluate(()=>hallReturns),1);assert.equal(await page.evaluate(()=>currentRoundId),null);
  await page.evaluate(()=>{currentRoundId=202;sessionView={sessions:[],proposal:null};window.dilemaBoardSnapshot.data.paused=true;window.dilemaBoardSnapshot.data.context_state={id:999};paintSessions();dilemaWorkbenchSync()});
  await page.locator('#r88Open_escape').click();assert.equal(await page.locator('#r88Drawer_pilotSaveSession').isEnabled(),false,'Pending context decision still blocks save');
  await page.evaluate(()=>{delete dilemaBoardSnapshot.data.context_state;dilemaPresenceView.my_presence='absent';paintSessions();dilemaWorkbenchSync()});
  assert.equal(await page.locator('#r88Drawer_pilotSaveSession').isEnabled(),false,'Absent participant cannot save');
  await page.evaluate(()=>{dilemaPresenceView.my_presence='present';dilemaBoardSnapshot.data.paused=false;paintSessions();dilemaWorkbenchSync()});
  assert.equal(await page.locator('#r88Drawer_pilotSaveSession').isEnabled(),false,'Save requires pause');
  await page.locator('#r88DrawerClose').click();
  await page.evaluate(()=>{
   for(const id of ['pilotAssistantOpen','pilotAssistantRequest','pilotProclamaBtn','pilotSecretRevoteAction']){
    const b=document.createElement('button');b.id=id;b.textContent=id;document.getElementById('r88SourceBank').appendChild(b);
   }
   const pro=document.getElementById('pilotProclamaBtn');Object.assign(pro.dataset,{owned:'true',ownedRound:'202',ownedUser:'guest'});
   dilemaBoardSnapshot.data.mine_choice='N';dilemaBoardSnapshot.data.secret_revote_mine=true;
   dilemaBoardSnapshot.data.medicine_state={busy:false,can_launch:false,inventory:{limbo:1,robo:1,senuelo:1,cambio:1,espejo:1,antidoto:1}};
   window.dilemaAssistantAccess={round:202,user:'guest',data:{cycle:1,token:true}};
   paintSessions();dilemaWorkbenchSync();
  });
  for(const id of ['pilotAssistantOpen','pilotProclamaBtn','pilotSecretRevoteAction']){
   assert.equal(await page.locator('#r88Tool_'+id).isVisible(),true,'Neutral inventory must remain visible: '+id);
   assert.equal(await page.locator('#r88Tool_'+id).isEnabled(),false,'Neutral inventory must be locked: '+id);
  }
  await page.locator('#r88Open_help').click();
  assert((await page.locator('#r88Drawer_pilotAssistantRequest').textContent()).includes('✦'),'Request help uses assistant icon');
  await page.locator('#r88DrawerClose').click();
  await page.evaluate(()=>{dilemaBoardSnapshot.data.mine_choice='A';dilemaBoardSnapshot.data.medicine_state.can_launch=true;paintSessions();dilemaWorkbenchSync()});
  assert.equal(await page.locator('#r88Tool_pilotMedicine_robo').isVisible(),false);
  assert.equal(await page.locator('#r88Open_medicine').isVisible(),true);
  assert.equal(await page.locator('#r88Open_medicine').isEnabled(),false);
  await page.evaluate(()=>document.getElementById('r88Open_medicine').click());
  assert.equal(await page.locator('#r88Drawer').isVisible(),false);
  assert.equal(await page.evaluate(()=>r86ActionLocked('pilotMedicine_robo')),true);
  for(const id of ['pilotProclamaBtn','pilotSecretRevoteAction'])assert.equal(await page.locator('#r88Tool_'+id).isEnabled(),true);
  assert.equal(await page.locator('#r88Tool_pilotAssistantOpen').isEnabled(),true);
  assert.match(html,/CREAR PARTIDA/);assert.match(html,/construction-btn[^>]*disabled/);
  // R105: exercise actual moderation script and inventory with a neutral participant.
  await page.evaluate(()=>{
   currentRoundId=202;currentRoomStatus='playing';currentRoundStatus='debate';dilemaBoardSnapshot.data.mine_choice='N';dilemaBoardSnapshot.data.paused=false;
   window.mockModeration={style:'moderated',seconds:90,suspended:false,server_now:new Date().toISOString(),finished:false,ever_moderated:true,proposal:null,queue:[{id:2,name:'Neutral',me:true}],turn:{id:1,name:'Other',me:false,deadline:new Date(Date.now()+90000).toISOString(),remaining_ms:90000,mine_rating:null},can_request:true,can_end:false,can_rate:true,can_propose:true,results:null};
   dilemaBoardSnapshot.data.moderation_state=mockModeration;window.pilotRefresh=async()=>{dilemaBoardSnapshot.data.moderation_state=structuredClone(mockModeration)};
   window.sb={rpc:async(name,args)=>{calls.push({name,args});if(name==='debate_moderation_action'){
    if(args.p_action==='rate')mockModeration.turn.mine_rating=args.p_score;
    if(args.p_action==='request')mockModeration.can_request=false;
    if(args.p_action==='pass'||args.p_action==='cede'){mockModeration.turn={id:2,name:'Next',me:false,deadline:new Date(Date.now()+90000).toISOString(),remaining_ms:90000,mine_rating:null};mockModeration.can_end=false;mockModeration.can_rate=true;mockModeration.can_request=true}
    if(args.p_action==='propose'){mockModeration.proposal={id:20,style:args.p_style,seconds:args.p_seconds,yes:1,no:0,players:3,mine:true,can_vote:false};mockModeration.suspended=true;mockModeration.can_rate=false;mockModeration.can_request=false;mockModeration.can_end=false;mockModeration.can_propose=false;mockModeration.turn.deadline=null;mockModeration.turn.remaining_ms=40000}
   }return {data:structuredClone(mockModeration),error:null}},from:()=>({update:()=>({eq:async()=>({error:null})})})};
  });
  const moderation=scripts.find(s=>s.includes('R105: moderation is authoritative'));
  await page.addScriptTag({content:moderation});await page.evaluate(async()=>{await pilotRefresh();dilemaWorkbenchSync()});
  assert.equal(await page.locator('#r105Moderation').isVisible(),true);
  assert.match(await page.locator('#r105Clock').textContent(),/1:3[01]/);
  assert.equal(await page.locator('#r88Tool_r105SpeechRequest').isVisible(),true,'N can request word');
  assert.equal(await page.locator('#r88Tool_r105SpeechRequest').isEnabled(),true);
  assert.equal(await page.locator('#r88Open_medicine').isEnabled(),false);
  assert.equal(await page.locator('#r88Tool_pilotProclamaBtn').isEnabled(),false,'N resource still locked');
  await page.locator('[data-rating="3"]').click();await page.waitForTimeout(40);
  assert.match(await page.locator('#r105MineRating').textContent(),/3\/5/);
  await page.locator('[data-rating="5"]').click();await page.waitForTimeout(40);
  assert.match(await page.locator('#r105MineRating').textContent(),/5\/5/);
  await page.locator('#r105Abstain').click();await page.waitForTimeout(40);
  assert.match(await page.locator('#r105MineRating').textContent(),/Sin valoración/);
  await page.locator('#r88Tool_r105SpeechRequest').click();await page.waitForTimeout(40);
  assert.equal(await page.locator('#r88Tool_r105SpeechRequest').isEnabled(),false,'Already queued');
  await page.evaluate(async()=>{mockModeration.turn.me=true;mockModeration.can_end=true;mockModeration.can_rate=false;mockModeration.can_request=false;await pilotRefresh()});
  assert.equal(await page.locator('#r105Rating').isVisible(),false,'Cannot rate own intervention');
  assert.equal(await page.locator('#r88Tool_r105SpeechPass').isEnabled(),true);
  assert.equal(await page.locator('#r88Tool_r105SpeechCede').isEnabled(),true);
  await page.locator('#r88Tool_r105SpeechCede').click();await page.waitForTimeout(40);
  assert.equal(await page.evaluate(()=>calls.at(-1).args.p_action),'cede');
  assert.equal(await page.locator('#r105Rating').isVisible(),true);
  await page.locator('#r105ModeButton').click();
  assert.equal(await page.locator('#r105StyleDialog').isVisible(),true);
  await page.locator('#r105ProposeFree').click();await page.waitForTimeout(60);
  assert.match(await page.locator('#r105StyleCount').textContent(),/1 SÍ.*3 PRESENTES.*MAYORÍA/);
  assert.equal(await page.locator('[data-style-vote="yes"]').isEnabled(),false);
  assert.equal(await page.locator('[data-rating="3"]').isEnabled(),false);
  assert.equal(await page.locator('#r105Clock').textContent(),'0:40');
  await page.evaluate(async()=>{mockModeration.proposal=null;mockModeration.style='free';mockModeration.can_propose=true;mockModeration.turn=null;mockModeration.can_rate=false;mockModeration.can_end=false;await pilotRefresh()});
  assert.equal(await page.locator('#r105Clock').isVisible(),false);
  assert.equal(await page.locator('#r88Tool_r105SpeechPass').isVisible(),false);
  await page.setViewportSize({width:390,height:844});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'No mobile overflow');
  await page.evaluate(async()=>{mockModeration.finished=true;mockModeration.results=[{name:'<script>test</script>',me:true,score:5,winner:true,interventions:2,rated_interventions:1,votes:2},{name:'No votes',me:false,score:null,winner:false,interventions:1,rated_interventions:0,votes:0}];await r105FinishModeration(202,101)});
  assert.equal(await page.locator('#r105Results').isVisible(),true);
  assert.match(await page.locator('#r105ResultsList').textContent(),/5.00\/5/);
  assert.match(await page.locator('#r105ResultsList').textContent(),/SIN VALORACIÓN/);
  assert.equal(await page.locator('#r105ResultsList script').count(),0,'Names render as text');
  await page.locator('#r105ResultsHall').click();await page.waitForTimeout(40);
  assert.equal(await page.locator('#r105Results').isVisible(),false);
  assert.deepEqual(errors,[]);console.log('PASS R105: neutral word controls, rating changes and abstention, own-rating lock, cede, shared pause and mode proposal, free clock hidden, mobile layout, safe results and hall return; pure debate drawer visible and disabled, medicines hidden despite old inventory, debate resources locked at N and enabled at A, game access disabled; inline scripts parse; real drawer click, nonhost save, majority vote, hall return and pending/absent/unpaused locks');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
