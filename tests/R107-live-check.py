"""Authorized smoke test of deployed functions; never print credentials."""
import json,re,uuid,urllib.request,sys
from pathlib import Path
html=Path(__file__).parents[1].joinpath('test-v0.1.16.html').read_text()
root=re.search(r'const SUPABASE_URL\s*=\s*"([^"]+)"',html)[1]
anon=re.search(r'const SUPABASE_KEY\s*=\s*"([^"]+)"',html)[1]
state_file=Path('/tmp/dilema-r107-live.json')
def call(path,body=None,token=None,method=None,timeout=120):
 headers={'apikey':anon,'content-type':'application/json','origin':'https://xtronzio.github.io','prefer':'return=representation'}
 if token:headers['authorization']='Bearer '+token
 req=urllib.request.Request(root+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method or ('GET' if body is None else 'POST'))
 with urllib.request.urlopen(req,timeout=timeout) as res:
  data=res.read();return json.loads(data) if data else None
if sys.argv[1]=='auth':
 auth=call('/auth/v1/signup',{'data':{}});state={'user':auth['user']['id'],'token':auth['access_token']}
 state_file.write_text(json.dumps(state));state_file.chmod(0o600);print('Temporary anonymous test session ready')
else:
 state=json.loads(state_file.read_text());token=state['token']
 if sys.argv[1]=='training':
  session=call('/rest/v1/private_dilemma_sessions',{'question':'Dilema hipotético: tu amigo copia en un examen. Guardar el secreto conserva su confianza; contarlo evita una injusticia pero puede romper la amistad. ¿Qué eliges?','option_a':'Contarlo al profesor','option_b':'Guardar el secreto','choice':'A','interaction_mode':'training'},token)[0];state['session']=session['id'];state_file.write_text(json.dumps(state))
  replies=[]
  for choice,message in [('A','Defiendo contarlo porque quienes estudiaron merecen una evaluación justa.'),('B','Ahora defiendo guardar el secreto: primero hablaría con mi amigo para que lo reconozca él.')]:
   if choice=='B':call('/rest/v1/private_dilemma_sessions?id=eq.'+session['id'],{'choice':choice},token,'PATCH')
   reply=call('/functions/v1/private-dialogue',{'sessionId':session['id'],'requestId':str(uuid.uuid4()),'message':message},token)
   assert reply.get('status')=='ready',reply
   assert reply['turn']['mode']=='IA','AI unavailable: '+str(reply['turn']['mode'])
   replies.append({k:reply['turn'][k] for k in ['choice','reflection','question','mode']})
  print(json.dumps({'training':'PASS','replies':replies},ensure_ascii=False))
 elif sys.argv[1]=='feedback':
  reply=call('/functions/v1/private-dialogue',{'sessionId':state['session'],'requestId':str(uuid.uuid4()),'message':'Valora mis argumentos del entrenamiento. Señala con un ejemplo mi razón más sólida, una debilidad o contradicción y cómo mejorarla. No puntúes mi postura ni inventes un ganador.'},token)
  assert reply.get('status')=='ready' and reply['turn']['mode']=='IA',reply
  print(json.dumps({'feedback':'PASS','reflection':reply['turn']['reflection'],'question':reply['turn']['question']},ensure_ascii=False))
 elif sys.argv[1]=='news':
  reply=call('/functions/v1/current-dilemmas',{'intensity':3,'theme':'ALEATORIO'},token)
  print(json.dumps({'status':reply.get('status'),'fallback':reply.get('fallback'),'candidates':[{'id':d['id'],'title':d.get('news_meta',{}).get('title'),'date':d.get('news_meta',{}).get('date'),'url':d.get('news_meta',{}).get('url'),'policy':d.get('news_meta',{}).get('selection_policy')} for d in reply.get('candidates',[])]},ensure_ascii=False))
  assert reply.get('status')=='ready' and reply.get('candidates') and not reply.get('fallback'),'Live news returned fallback'
  assert all(d.get('news_meta',{}).get('selection_policy')=='grounded-publishers-v3' for d in reply['candidates'])
 elif sys.argv[1]=='cleanup':
  if state.get('session'):call('/rest/v1/private_dilemma_sessions?id=eq.'+state['session'],token=token,method='DELETE')
  call('/auth/v1/logout',{},token);print('Temporary private training removed and test session signed out')
