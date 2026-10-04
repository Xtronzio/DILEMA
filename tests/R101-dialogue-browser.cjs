const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const html=fs.readFileSync(process.argv[2]||__dirname+'/../test-v0.1.16.html','utf8');
const scripts=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].map(m=>m[1]);
const base=html.slice(html.indexOf('let privateDilemma=null'),html.indexOf('async function openDebateHelpHistory(){'));
const dialogue=scripts.find(s=>s.includes('R93: private dialogue,'));
const thinking=scripts.find(s=>s.includes("const E=id=>document.getElementById(id),expanded=new Set()"));
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.DILEMA_CHROMIUM_EXECUTABLE?{executablePath:process.env.DILEMA_CHROMIUM_EXECUTABLE,args:['--no-sandbox','--disable-gpu','--disable-dev-shm-usage']}:{})});
 try{
  const page=await browser.newPage();
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setContent(html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,''));
  await page.evaluate(()=>{
   window.currentUserId='tester';window.calls=[];window.savedRows=[];window.deferred=false;window.failNext=false;
   let serial=10;Object.defineProperty(crypto,'randomUUID',{value:()=>`00000000-0000-4000-8000-${String(++serial).padStart(12,'0')}`});
   window.testSession={id:'00000000-0000-4000-8000-000000000001',question:'LA EXPULSIÓN',option_a:'A QUIEN ME ACOSÓ',option_b:'A MI AMIGO',choice:null,allow_doubt:true};
   window.renderDilemmaCopy=(e,s)=>e.textContent=s;window.guideHistoryCounts=()=>({matching:0,total:0});window.syncCharacterCounters=()=>{};
   window.showScreen=id=>{document.querySelectorAll('.screen').forEach(s=>s.classList.toggle('active',s.id===id))};
   window.sb={from(table){let patch=null,session=null;const q={select(){return q},eq(k,v){if(k==='session_id')session=v;return q},order(){return q},limit(){return q},lt(){return q},update(v){patch=v;return q},single(){return run()},maybeSingle(){return run()},then(resolve,reject){return run().then(resolve,reject)}};
    async function run(){if(table==='private_dilemma_sessions'){if(patch){calls.push(['save',patch.choice]);Object.assign(testSession,patch)}return {data:{...testSession}}}if(table==='private_dilemma_guides')return {data:[]};return {data:savedRows.filter(r=>r.session_id===session).map(r=>({...r}))}}return q;},functions:{async invoke(name,{body}){
    calls.push([name,body]);if(deferred)await new Promise(r=>window.releaseReply=r);if(failNext){failNext=false;return {error:{message:'NETWORK_ERROR'}}}
    const turn={id:body.requestId,session_id:body.sessionId,turn_number:savedRows.filter(r=>r.session_id===body.sessionId).length+1,message:body.message,choice:testSession.choice||'N',status:'ready',reflection:'OBSERVACIÓN',question:'¿Qué coste asumirías?',mode:'IA'};savedRows.push(turn);return {data:{status:'ready',turn}};
   }}};
   const NativeObserver=window.MutationObserver;window.mutationDeliveries=0;
   // Limit observer callbacks only for diagnosis: fail instead of hanging Chromium forever.
   window.MutationObserver=class extends NativeObserver{constructor(fn){super((...args)=>{window.mutationDeliveries++;if(window.mutationDeliveries<150)fn(...args)})}};
  });
  await page.addScriptTag({content:base});await page.addScriptTag({content:dialogue});await page.addScriptTag({content:thinking});
  await page.evaluate(()=>document.dispatchEvent(new Event('DOMContentLoaded')));
  await page.evaluate(()=>{privateDilemma={...testSession};renderPrivateDilemma()});
  await page.waitForTimeout(80);
  assert.equal(await page.evaluate(()=>calls.length),0,'Unchosen A/B must not start assistant');
  assert.equal(await page.locator('#privateVoteA').isEnabled(),true);
  await page.locator('#privateVoteA').click();await page.waitForTimeout(100);
  assert((await page.evaluate(()=>mutationDeliveries))<150,'Thinking observer loops on its own DOM updates and freezes input');
  assert.equal(await page.evaluate(()=>privateDilemma.choice),'A');
  assert.equal(await page.locator('#privateVoteA').getAttribute('aria-pressed'),'true');
  assert.equal(await page.locator('#privateVoteB').isEnabled(),true);
  assert.equal(await page.evaluate(()=>savedRows.length),1);
  await page.locator('#privatePlanteamientoTitle').click();await page.locator('#privateVoteB').click();await page.waitForTimeout(80);
  assert.equal(await page.evaluate(()=>privateDilemma.choice),'B');assert.equal(await page.evaluate(()=>savedRows.length),1);
  await page.locator('#privateVoteN').click();await page.waitForTimeout(80);assert.equal(await page.evaluate(()=>privateDilemma.choice),'N');
  await page.locator('#privateDialogueCounter').click();await page.waitForTimeout(80);assert.equal(await page.evaluate(()=>savedRows.length),2,JSON.stringify(await page.evaluate(()=>({calls,field:document.getElementById('privateDialogueInput').value,disabled:document.getElementById('privateDialogueCounter').disabled,status:document.getElementById('privateDialogueStatus').textContent}))));
  assert((await page.locator('#privateDialogueLog').textContent()).includes('OBSERVACIÓN'));
  await page.locator('.r99-turn-toggle').first().click();assert.equal(await page.locator('.r99-turn-toggle').first().getAttribute('aria-expanded'),'true');
  await page.evaluate(()=>{paintPrivateDialogue()});await page.waitForTimeout(50);assert.equal(await page.locator('.r99-turn-toggle').first().getAttribute('aria-expanded'),'true');
  await page.locator('.r99-turn-toggle').last().click();assert.equal(await page.locator('.r99-turn-toggle').last().getAttribute('aria-expanded'),'false');
  await page.evaluate(()=>paintPrivateDialogue());await page.waitForTimeout(50);assert.equal(await page.locator('.r99-turn-toggle').last().getAttribute('aria-expanded'),'false','Collapsed latest turn must stay collapsed');
  await page.evaluate(()=>{testSession={id:'00000000-0000-4000-8000-000000000002',question:'Tengo un conflicto con mi amigo',option_a:'',option_b:'',choice:null};privateDilemma={...testSession};renderPrivateDilemma()});await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>savedRows.filter(r=>r.session_id===testSession.id).length),1);assert.equal(await page.locator('#privateVoteN').isVisible(),false);
  await page.evaluate(()=>renderPrivateDilemma());await page.waitForTimeout(50);assert.equal(await page.evaluate(()=>savedRows.filter(r=>r.session_id===testSession.id).length),1);
  await page.evaluate(()=>{deferred=true});await page.locator('#privateDialogueInput').fill('Mi argumento');await page.locator('#privateDialogueSend').click();await page.waitForTimeout(30);
  assert.equal(await page.locator('#privateDialogueSend').isEnabled(),false);await page.evaluate(()=>{deferred=false;releaseReply()});await page.waitForTimeout(80);
  assert.equal(await page.locator('#privateDialogueInput').inputValue(),'');assert.equal(await page.locator('#privateDialogueCounter').isEnabled(),true);
  await page.evaluate(()=>{failNext=true});await page.locator('#privateDialogueInput').fill('No perder mi texto');await page.locator('#privateDialogueSend').click();await page.waitForTimeout(80);
  assert.equal(await page.locator('#privateDialogueInput').inputValue(),'No perder mi texto');assert.equal(await page.locator('#privateDialogueInput').isEnabled(),true);
  await page.locator('[data-dialogue-retry]').click();await page.waitForTimeout(80);assert.equal(await page.locator('[data-dialogue-retry]').count(),0);
  assert.equal(errors.length,0,errors.join('\n'));assert((await page.evaluate(()=>mutationDeliveries))<150);
  console.log('PASS: real Chromium clicks A/B/N, tools, open topic, single kickoff, collapse persistence, slow reply, retry and unlocked controls');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
