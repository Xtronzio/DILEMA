const fs=require('node:fs'),assert=require('node:assert/strict'),{chromium}=require('playwright');
const html=fs.readFileSync(__dirname+'/../test-v0.1.16.html','utf8');
const styles=[...html.matchAll(/<style\b[^>]*>[\s\S]*?<\/style>/gi)].map(m=>m[0]).join('\n');
const green='rgb(74, 222, 128)';
(async()=>{const browser=await chromium.launch({headless:true,executablePath:process.env.DILEMA_CHROMIUM_EXECUTABLE,args:['--no-sandbox','--disable-gpu','--disable-dev-shm-usage']});try{
 const page=await browser.newPage({viewport:{width:390,height:844}});
 // All production styles participate, including old rules and contextual overrides.
 const outlined=[
  '<section id="catalogDilemmas"><button class="selection-question selected" disabled>Catálogo de mesa</button><button class="selection-question">Otro dilema</button></section>',
  '<section id="privateCatalog"><button class="selection-question selected">Pregunta individual</button></section>',
  '<section id="voting"><button class="vote-option selected">Mi voto inicial</button><button class="vote-option">Otro voto</button></section>',
  '<section id="result"><div class="result-item result-my-vote">Mi resultado</div><div class="result-item">Otro resultado</div></section>',
  '<div id="resultNeutral" class="neutral-result result-my-vote">Mi resultado N</div>',
  '<section id="debate"><div class="debate-option pilot-my-vote">Mi postura</div><div class="debate-option">Otra postura</div><div id="pilotVoteN" class="neutral-result pilot-my-vote">Mi postura N</div></section>',
  '<section id="savedGroupView"><div class="saved-option saved-last-choice">Mi último voto</div><div class="saved-option">Otra postura guardada</div></section>'
 ];
 const filled=[
  '<button class="avatar-tab active">Categoría de avatar</button><button class="avatar selected">Avatar</button>',
  '<button class="choice-chip selected">Tema</button><div class="audience-choice"><button class="choice-btn active">Público</button></div>',
  '<button class="selection-chip selected" disabled>Intensidad</button><button class="selection-chip current-ai selected">Actualidad</button>',
  '<div id="dilemmaProposal"><div id="proposalVote"><button class="btn is-selected">Propuesta</button></div></div>',
  '<div id="hallRejoinVote"><button class="btn is-selected">Regreso</button></div>',
  '<div id="debatePilotPanel"><div id="pilotUnanimity"><button class="pilot-selected">Unanimidad</button></div><div id="pilotPauseProposal"><div class="pilot-actions"><button class="pilot-selected">Pausa</button></div></div><div id="pilotGroupRevoteProposal"><div class="pilot-actions"><button class="pilot-selected">Revoto</button></div></div></div>',
  '<div id="pilotAdmissionVoteBox"><div class="limbo-actions"><button class="pilot-selected">Admisión</button></div></div>',
  '<div class="r86-session-box"><button class="pilot-selected">Guardar mesa</button></div><div id="pilotContextDecision"><button class="selected">Contexto</button></div>',
  '<button id="worldDiscardVote" class="selected">Descartar</button><div id="proclamationComposer"><button class="selected">Destinatario</button></div>',
  '<div id="pilotAssistantModal"><div class="am-route-buttons"><button class="selected">Ruta</button></div></div>',
  '<div id="privateBoard"><div class="private-options"><button class="selected">Postura privada</button></div><button id="privateVoteN" class="selected">Duda privada</button></div>',
  '<div id="r88Drawer"><div id="r88ViewSettings"><button class="selected">Vista</button></div></div>',
  '<div id="debateStyleChoice"><button class="r110-mode selected">Modalidad</button></div><div class="r105-duration"><button class="selected">Duración</button></div><div class="r105-rating"><button class="selected">Valoración</button></div>'
 ];
 await page.setContent(styles+outlined.join('')+'<div id="filledCases">'+filled.join('')+'</div>');
 const outlineLocator=page.locator('.selection-question.selected,.vote-option.selected,.result-my-vote,.pilot-my-vote,.saved-last-choice');
 assert.equal(await outlineLocator.count(),8);
 for(const e of await outlineLocator.all()){const s=await e.evaluate(e=>{const s=getComputedStyle(e);return {border:s.borderColor,shadow:s.boxShadow,bg:s.backgroundColor,text:s.color}});assert.equal(s.border,green);assert.equal(s.shadow,'none');assert.notEqual(s.bg,'rgb(255, 255, 255)');assert.notEqual(s.text,'rgb(0, 0, 0)')}
 const filledChoices=page.locator('#filledCases .selected,#filledCases .pilot-selected,#filledCases .is-selected,#filledCases .active');const filledCount=await filledChoices.count();
 for(const e of await filledChoices.all())assert.notEqual(await e.evaluate(e=>getComputedStyle(e).borderColor),green,'Filled choice must never receive green outline');
 for(const e of await page.locator('#catalogDilemmas .selection-question:not(.selected),#voting .vote-option:not(.selected),#result .result-item:not(.result-my-vote),#debate .debate-option:not(.pilot-my-vote),.saved-option:not(.saved-last-choice)').all())assert.notEqual(await e.evaluate(e=>getComputedStyle(e).borderColor),green,'Unselected alternative must remain neutral');
 const saved=page.locator('.saved-option');const backgroundBefore=await saved.nth(1).evaluate(e=>getComputedStyle(e).backgroundColor);assert.equal(await saved.nth(0).evaluate(e=>getComputedStyle(e).backgroundColor),backgroundBefore,'Saved vote changes border only');
 await page.evaluate(()=>{const options=document.querySelectorAll('.saved-option');options[0].classList.remove('saved-last-choice');options[1].classList.add('saved-last-choice')});assert.notEqual(await saved.nth(0).evaluate(e=>getComputedStyle(e).borderColor),green);assert.equal(await saved.nth(1).evaluate(e=>getComputedStyle(e).borderColor),green);
 await page.setContent(styles+'<main style="width:100%;max-width:390px;padding:24px"><p class="game-category">PRUEBA VISUAL · R112</p><h1 style="font-size:24px;text-align:center">MI VOTO O SELECCIÓN</h1><p style="font-weight:400;text-align:center;margin:24px 0 12px">SIN RELLENO · MARCO VERDE</p><button class="selection-question selected">Mi elección</button><button class="selection-question">Otra opción</button><p style="font-weight:400;text-align:center;margin:32px 0 12px">CON RELLENO · SIN MARCO VERDE</p><button class="selection-chip selected" style="width:100%">Mi elección</button><button class="selection-chip" style="width:100%;margin-top:10px">Otra opción</button></main>');
 await page.screenshot({path:'/workspace/scratch/DILEMA-R112-selecciones.jpg'});
 console.log(`PASS R112: 8 unfilled selected states use green; ${filledCount} filled selected states keep their own borders; unselected alternatives stay neutral; saved vote preserves background and switches exclusively`);
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
