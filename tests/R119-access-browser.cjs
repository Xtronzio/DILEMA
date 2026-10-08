const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const html=fs.readFileSync(__dirname+'/../test-v0.1.16.html','utf8');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.DILEMA_CHROMIUM_EXECUTABLE,args:['--no-sandbox','--disable-gpu','--disable-dev-shm-usage']});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   const owner=()=>localStorage.getItem('fixtureOwner')||'owner-A';
   const profiles=id=>[{id:'profile-'+id,name:id==='owner-A'?'JORGE':'AIMAR',avatar:'⚽',motto:''}];
   window.fixtureCalls=[];
   window.fixtureClient={
    auth:{async getUser(){return {data:{user:{id:owner()}}}},async getSession(){return {data:{session:{user:{id:owner()}}}}},async setSession(session){localStorage.setItem('fixtureOwner',session.access_token);return {data:{user:{id:owner()}}}},async signInAnonymously(){throw Error('Must not create a new identity')}},
    functions:{async invoke(name,{body}){
     fixtureCalls.push(body.action);
     if(name!=='access-link'||body.action!=='restore')return {data:{}};
     const id=body.token==='dl1_'+('A'.repeat(43))?'owner-A':body.token==='dl1_'+('B'.repeat(43))?'owner-B':null;
     if(!id)return {data:{error:'INVALID_LINK'}};
     return {data:{user_id:id,profiles:profiles(id),session:{access_token:id,refresh_token:'fixture'}}};
    }},
    from(table){let filterOwner;const q={select(){return q},eq(k,v){if(k==='user_id')filterOwner=v;return q},order(){return q},range(){return q},limit(){return q},maybeSingle(){return Promise.resolve({data:null})},then(a,b){return Promise.resolve({data:table==='saved_dilemma_library'?[{id:'dilemma-'+owner(),user_id:owner(),origin:'PRIV',question:'DILEMA DE '+owner(),created_at:'2026-10-08T10:00:00Z',choice:'A',is_pinned:false}].filter(r=>r.user_id===filterOwner):[]}).then(a,b)}};return q},
    async rpc(){return {data:null}}
   };
   if(!localStorage.getItem('dilema_profiles'))localStorage.setItem('dilema_profiles',JSON.stringify(profiles('owner-A')));
  });
  await page.route('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',r=>r.fulfill({contentType:'application/javascript',body:'window.supabase={createClient:()=>window.fixtureClient};'}));
  await page.route('https://fixture.test/**',r=>r.fulfill({contentType:'text/html',body:html}));
  await page.goto('https://fixture.test/DILEMA/test-v0.1.16.html');await page.evaluate(()=>openSavedDilemmas());
  assert.equal(await page.locator('#savedDilemmas > .access-warning').count(),2);
  assert.match(await page.locator('#savedDilemmas > .access-warning').nth(0).textContent(),/GUARDA TU ACCESO/);
  assert.match(await page.locator('#savedDilemmas > .access-warning').nth(1).textContent(),/CARGAR MI ACCESO/);
  await page.locator('.access-load > summary').click();
  const initialPlayer=await page.evaluate(()=>localPlayerId);
  for(const link of ['', 'texto', 'javascript:alert(1)', 'https://other.test/DILEMA/#access=dl1_'+('B'.repeat(43)), 'https://fixture.test/other/#access=dl1_'+('B'.repeat(43)), 'https://fixture.test/DILEMA/#access=bad', 'https://fixture.test/DILEMA/#access=dl1_'+('B'.repeat(43))+'&access=dl1_'+('A'.repeat(43))]){
   await page.locator('#portableLoadUrl').fill(link);await page.locator('#portableLoadButton').click();
   await page.waitForFunction(()=>document.getElementById('portableLoadUrl').getAttribute('aria-invalid')==='true');
   assert.equal(await page.locator('#portableLoadUrl').getAttribute('aria-invalid'),'true',JSON.stringify({link,errors,status:await page.locator('#portableLoadStatus').textContent()}));
   assert.equal(await page.evaluate(()=>currentUserId),'owner-A');assert.equal(await page.evaluate(()=>fixtureCalls.length),0);
  }
  const load=async(letter)=>{
   if(!await page.locator('#savedDilemmas').evaluate(e=>e.classList.contains('active')))await page.evaluate(()=>openSavedDilemmas());
   if(!await page.locator('.access-load').evaluate(e=>e.open))await page.locator('.access-load > summary').click();
   await page.locator('#portableLoadUrl').fill('  https://fixture.test/DILEMA/test-v0.1.16.html#access=dl1_'+letter.repeat(43)+'  ');
   await page.locator('#portableLoadButton').click();
   await page.waitForFunction(id=>currentUserId===id&&document.getElementById('savedDilemmas').classList.contains('active')&&!savedLibraryBusy,'owner-'+letter);
  };
  await load('B');
  assert.equal(await page.evaluate(()=>getProfiles()[0].name),'AIMAR');
  assert.match(await page.locator('#savedDilemmaList').textContent(),/owner-B/);assert.doesNotMatch(await page.locator('#savedDilemmaList').textContent(),/owner-A/);
  assert.equal(page.url(),'https://fixture.test/DILEMA/test-v0.1.16.html');
  const otherPlayer=await page.evaluate(()=>localPlayerId);assert.notEqual(otherPlayer,initialPlayer);
  assert.equal(await page.evaluate(()=>localStorage.getItem('dilema_local_player_id:owner-A')),initialPlayer);
  assert.equal(await page.evaluate(()=>localStorage.getItem('dilema_access_key:owner-B')),'dl1_'+('B'.repeat(43)));
  assert.equal(await page.evaluate(()=>sessionStorage.getItem('dilema_access_destination')),null);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await page.locator('.access-load > summary').click();
  await page.screenshot({path:__dirname+'/../../DILEMA-R119-access.png'});
  await load('A');assert.equal(await page.evaluate(()=>getProfiles()[0].name),'JORGE');assert.equal(await page.evaluate(()=>localPlayerId),initialPlayer);
  assert.match(await page.locator('#savedDilemmaList').textContent(),/owner-A/);
  assert.equal(await page.evaluate(()=>localStorage.getItem('dilema_access_key:owner-B')),'dl1_'+('B'.repeat(43)));
  await load('B');assert.equal(await page.evaluate(()=>localPlayerId),otherPlayer);
  await page.locator('.access-load > summary').click();
  await page.locator('#portableLoadUrl').fill('https://fixture.test/DILEMA/#access=dl1_'+('C'.repeat(43)));await page.locator('#portableLoadUrl').press('Enter');
  await page.waitForFunction(()=>document.getElementById('portableAccessMessage').textContent.includes('no es válido'));
  assert.equal(await page.evaluate(()=>localStorage.getItem('fixtureOwner')),'owner-B');
  assert.equal(await page.evaluate(()=>getProfiles()[0].name),'AIMAR');
  assert.equal(await page.locator('#portableAccessRetry').isVisible(),false);
  await page.locator('#portableAccessCancel').click();await page.waitForFunction(()=>currentUserId==='owner-B'&&document.getElementById('home').classList.contains('active'));
  assert.equal(await page.evaluate(()=>sessionStorage.getItem('dilema_access_destination')),null);
  assert.deepEqual(errors,[]);
  console.log('PASS R119: panel placement, invalid links, full-tab A→B→A→B, profile/history isolation, player identity isolation and reuse, private URL stripping, invalidated link preserves session, cancel recovery, Enter submit and mobile width; production HTML with mocked network.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
