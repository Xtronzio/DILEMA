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
  for(const id of ['pilotMedicine_robo','pilotMedicine_espejo','pilotMedicine_antidoto','pilotAssistantOpen','pilotProclamaBtn','pilotSecretRevoteAction']){
   assert.equal(await page.locator('#r88Tool_'+id).isVisible(),true,'Neutral inventory must remain visible: '+id);
   assert.equal(await page.locator('#r88Tool_'+id).isEnabled(),false,'Neutral inventory must be locked: '+id);
  }
  await page.locator('#r88Open_help').click();
  assert((await page.locator('#r88Drawer_pilotAssistantRequest').textContent()).includes('✦'),'Request help uses assistant icon');
  await page.locator('#r88DrawerClose').click();
  await page.evaluate(()=>{dilemaBoardSnapshot.data.mine_choice='A';dilemaBoardSnapshot.data.medicine_state.can_launch=true;paintSessions();dilemaWorkbenchSync()});
  assert.equal(await page.locator('#r88Tool_pilotMedicine_robo').isEnabled(),true);
  assert.equal(await page.locator('#r88Tool_pilotAssistantOpen').isEnabled(),true);
  assert.deepEqual(errors,[]);console.log('PASS: neutral inventory visible and locked, A unlocks it, help icon matches; inline scripts parse; real drawer click, nonhost save, majority vote, hall return and pending/absent/unpaused locks');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
