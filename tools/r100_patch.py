from pathlib import Path

path = Path('test-v0.1.16.html')
text = path.read_text(encoding='utf-8')


def rep(old: str, new: str, expected: int = 1) -> None:
    global text
    found = text.count(old)
    if found != expected:
        raise SystemExit(f'R100 patch guard failed: {old[:140]!r} found {found}, expected {expected}')
    text = text.replace(old, new)


rep('DILEMA · V0.1.16-010C-R99', 'DILEMA · V0.1.16-010C-R100')

rep(
    "let privateDialogueKey=null,privateDialogueRows=[],privateDialogueRun=0,privateDialogueSending=false,privateDialogueLoading=false,privateDialoguePoll=null,privateDialogueStamp='',privateDialogueHasOlder=false;",
    "let privateDialogueKey=null,privateDialogueRows=[],privateDialogueRun=0,privateDialogueSending=false,privateDialogueLoading=false,privateDialoguePoll=null,privateDialogueKickoffTimer=null,privateDialogueStamp='',privateDialogueHasOlder=false;"
)

old_schedule = """function privateDialogueSchedule(){
 clearTimeout(privateDialoguePoll);privateDialoguePoll=null;
 if(privateDialogueRows.some(t=>t.status==='pending'&&Date.now()-new Date(t.leased_at).getTime()<60000)&&pdElement('privateBoard')?.classList.contains('active'))privateDialoguePoll=setTimeout(()=>loadPrivateDialogue(),2200);
}
"""
new_schedule = """function privateDialogueSchedule(){
 clearTimeout(privateDialoguePoll);privateDialoguePoll=null;
 if(privateDialogueRows.some(t=>t.status==='pending'&&Date.now()-new Date(t.leased_at).getTime()<60000)&&pdElement('privateBoard')?.classList.contains('active'))privateDialoguePoll=setTimeout(()=>loadPrivateDialogue(),2200);
}
function privateDialogueKickoff(){
 clearTimeout(privateDialogueKickoffTimer);privateDialogueKickoffTimer=null;
 const key=privateDialogueCurrent();
 if(!key||key!==privateDialogueKey||!privateDilemma||privateDialogueRows.length||privateDialogueSending||privateDialoguePending())return;
 const openTopic=!privateDilemma.option_a&&!privateDilemma.option_b;
 const hasChosenPosture=!!privateDilemma.choice;
 // An A/B dilemma must never start the assistant before the person has chosen A, B or EN DUDA.
 if(!openTopic&&!hasChosenPosture)return;
 // Creation/posture saves use privateBusy. Retry instead of losing the first assistant turn in that small window.
 if(privateBusy||privateDialogueLoading){privateDialogueKickoffTimer=setTimeout(privateDialogueKickoff,180);return;}
 const message=String(privateDilemma.question||'').trim();if(!message)return;
 void sendPrivateDialogue({id:privateDilemma.id,turn_number:1,message});
}
"""
rep(old_schedule, new_schedule)

rep(
    "const empty=document.createElement('p');empty.className='pd-note';empty.textContent='Vamos a explorar tu dilema paso a paso. Puedes escribir tus razones o tus dudas.';log.appendChild(empty);",
    "const empty=document.createElement('p');empty.className='pd-note';empty.textContent=(!privateDilemma.option_a&&!privateDilemma.option_b)?'DILEMA va a partir del tema que has planteado. También puedes añadir algo más cuando quieras.':privateDilemma.choice?'DILEMA está abriendo la conversación desde tu postura actual.':'Elige A, B o ESTOY EN DUDA para abrir la conversación con DILEMA.';log.appendChild(empty);"
)

old_bind = """function bindPrivateDialogue(){
 const key=privateDialogueCurrent();if(!key)return;
 if(key!==privateDialogueKey){
  clearTimeout(privateDialoguePoll);privateDialogueRun++;privateDialogueLoading=false;privateDialogueSending=false;
  privateDialogueKey=key;privateDialogueRows=[];privateDialogueStamp='';privateDialogueHasOlder=false;
  pdElement('privateDialogueInput').value=privateDialogueDrafts.get(key)||'';privateDialogueStatus('El diálogo se guarda con este dilema.');
  pdElement('privatePlanteamiento').open=!privateDilemma.choice;
  void loadPrivateDialogue().then(loaded=>{
   if(loaded&&key===privateDialogueCurrent()&&key===privateDialogueKey&&!privateDialogueRows.length&&!privateBusy)void sendPrivateDialogue({id:privateDilemma.id,turn_number:1,message:privateDilemma.option_a?'Quiero explorar este dilema. Ayúdame a empezar.':'Quiero explorar este tema. Ayúdame a aclarar qué quiero resolver y qué importa de verdad.'});
  });
 }
 paintPrivateDialogue();privateDialogueSchedule();window.syncCharacterCounters?.();
}
"""
new_bind = """function bindPrivateDialogue(){
 const key=privateDialogueCurrent();if(!key)return;
 if(key!==privateDialogueKey){
  clearTimeout(privateDialoguePoll);clearTimeout(privateDialogueKickoffTimer);privateDialogueKickoffTimer=null;privateDialogueRun++;privateDialogueLoading=false;privateDialogueSending=false;
  privateDialogueKey=key;privateDialogueRows=[];privateDialogueStamp='';privateDialogueHasOlder=false;
  pdElement('privateDialogueInput').value=privateDialogueDrafts.get(key)||'';privateDialogueStatus('El diálogo se guarda con este dilema.');
  pdElement('privatePlanteamiento').open=!privateDilemma.choice;
  void loadPrivateDialogue().then(loaded=>{if(loaded&&key===privateDialogueCurrent()&&key===privateDialogueKey)privateDialogueKickoff()});
 }
 paintPrivateDialogue();privateDialogueSchedule();privateDialogueKickoff();window.syncCharacterCounters?.();
}
"""
rep(old_bind, new_bind)

# The helper above now owns automatic first-turn behavior. Guard against reintroducing the synthetic kickoff copy.
if "Quiero explorar este dilema. Ayúdame a empezar." in text or "Quiero explorar este tema. Ayúdame a aclarar" in text:
    raise SystemExit('R100 guard failed: synthetic private-dialogue kickoff still exists')

# R99's thought-map should ignore the new hidden first turn because it carries the real question.
rep(
    "const ready=privateDialogueRows.filter(t=>t.status==='ready'),last=ready.at(-1),own=[...privateDialogueRows].reverse().find(t=>t.message&&!/^Quiero explorar este (dilema|tema)\\./.test(t.message));",
    "const ready=privateDialogueRows.filter(t=>t.status==='ready'),last=ready.at(-1),own=[...privateDialogueRows].reverse().find(t=>t.message&&t.id!==privateDilemma?.id);"
)

# Final guards.
for needle, expected in [
    ('DILEMA · V0.1.16-010C-R100', 1),
    ('function privateDialogueKickoff(){', 1),
    ("if(!openTopic&&!hasChosenPosture)return;", 1),
    ("privateDialogueKickoffTimer=setTimeout(privateDialogueKickoff,180)", 1),
    ("void sendPrivateDialogue({id:privateDilemma.id,turn_number:1,message});", 1),
    ("paintPrivateDialogue();privateDialogueSchedule();privateDialogueKickoff();window.syncCharacterCounters?.();", 1),
]:
    found = text.count(needle)
    if found != expected:
        raise SystemExit(f'R100 final guard failed: {needle!r}: {found} != {expected}')

path.write_text(text, encoding='utf-8')
print('R100 patch applied')
