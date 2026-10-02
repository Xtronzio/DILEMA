const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(fs.existsSync(__dirname+'/private-dialogue.ts')?__dirname+'/private-dialogue.ts':__dirname+'/../supabase/functions/private-dialogue/index.ts','utf8');new vm.Script(source);
const uid='00000000-0093-4000-8000-000000000001',sid='00000000-0093-4000-8000-000000000002',rid='00000000-0093-4000-8000-000000000003',lease='00000000-0093-4000-8000-000000000004';
const env={SUPABASE_URL:'https://example.supabase.co',SUPABASE_ANON_KEY:'ANON',SUPABASE_SERVICE_ROLE_KEY:'SERVER_ONLY',OPENAI_API_KEY:'AI_SERVER_ONLY',DILEMA_AI_MODEL:'gpt-6-luna'};
const calls=[];let handle,providerFail=false,authFail=false,prepareError=null,preparedStatus='prepared';
const context={question:'QUESTION',option_a:'A',option_b:'B',choice:'N',context:'USER CONTEXT',memory:'EARLIER REASONS',message:'CURRENT ARGUMENT',history:[{choice:'A',message:'EARLIER ARGUMENT',reflection:'EARLIER REFLECTION',question:'EARLIER QUESTION?'}]};
const c={Deno:{env:{get:k=>env[k]},serve:f=>handle=f},Response,Request,AbortSignal,console:{error(){}},fetch:async(url,options={})=>{
 const body=options.body?JSON.parse(options.body):null;calls.push({url,options,body});
 if(url.endsWith('/auth/v1/user'))return Response.json(authFail?{}:{id:uid},{status:authFail?401:200});
 if(url.endsWith('/prepare_private_dialogue')){
  if(prepareError)return Response.json({message:prepareError},{status:400});
  return Response.json(preparedStatus==='prepared'?{status:'prepared',request_id:rid,lease_id:lease,user_id:uid,context}:{status:preparedStatus,turn:{id:rid,message:'CURRENT ARGUMENT'}});
 }
 if(url==='https://api.openai.com/v1/responses')return providerFail?Response.json({error:{}},{status:429}):Response.json({output:[{content:[{type:'output_text',text:JSON.stringify({reflection:'SHORT REPLY',question:'ONE QUESTION?',memory:'UPDATED MEMORY'})}]}],usage:{input_tokens:100,input_tokens_details:{cached_tokens:20},output_tokens:40}});
 if(url.endsWith('/finish_private_dialogue'))return Response.json({status:'ready',turn:{id:rid,message:'CURRENT ARGUMENT',reflection:body.p_reflection,question:body.p_question,mode:body.p_mode}});
 throw Error('Unexpected request: '+url);
}};
vm.createContext(c);vm.runInContext(source,c);
const request=(body={sessionId:sid,requestId:rid,message:'CURRENT ARGUMENT'},token='Bearer USER')=>new Request('https://example/private-dialogue',{method:'POST',headers:{authorization:token},body:JSON.stringify(body)});
(async()=>{
 let res=await handle(request()),data=await res.json();assert.equal(res.status,200);assert.equal(data.turn.mode,'IA');
 const ai=calls.find(x=>x.url.includes('api.openai.com'));assert.equal(ai.body.model,'gpt-6-luna');assert.equal(ai.body.store,false);assert.equal(ai.body.max_output_tokens,1300);assert.equal(ai.body.input.length,4);assert(ai.body.input[0].content.includes('EARLIER REASONS'));assert(ai.body.input[0].content.includes('"postura_actual":"N"'));assert(ai.body.input[1].content.includes('EARLIER ARGUMENT'));assert.equal(ai.body.input.at(-1).content,'CURRENT ARGUMENT');
 const save=calls.find(x=>x.url.endsWith('/finish_private_dialogue'));assert.equal(save.options.headers.authorization,'Bearer SERVER_ONLY');assert.equal(save.body.p_usage.input_tokens,100);assert.equal(save.body.p_memory,'UPDATED MEMORY');assert(!JSON.stringify(data).includes('SERVER_ONLY'));assert(!JSON.stringify(data).includes('AI_SERVER_ONLY'));
 calls.length=0;preparedStatus='ready';res=await handle(request());assert.equal(res.status,200);assert(!calls.some(x=>x.url.includes('api.openai.com')));assert(!calls.some(x=>x.url.endsWith('/finish_private_dialogue')));
 calls.length=0;preparedStatus='pending';res=await handle(request());assert.equal((await res.json()).status,'pending');assert(!calls.some(x=>x.url.includes('api.openai.com')));
 preparedStatus='prepared';providerFail=true;res=await handle(request());data=await res.json();assert.equal(data.turn.mode,'BASICA');assert(data.turn.question);context.option_a='';context.option_b='';res=await handle(request());data=await res.json();assert(data.turn.question.includes('situación'));context.option_a='A';context.option_b='B';providerFail=false;
 calls.length=0;authFail=true;res=await handle(request());assert.equal(res.status,401);assert(!calls.some(x=>x.url.includes('api.openai.com')));authFail=false;
 calls.length=0;prepareError='PRIVATE_SESSION_NOT_FOUND';res=await handle(request());assert.equal(res.status,404);assert(!calls.some(x=>x.url.includes('api.openai.com')));
 prepareError='DIALOGUE_RATE_LIMIT';res=await handle(request());assert.equal(res.status,429);prepareError=null;
 calls.length=0;res=await handle(request({sessionId:sid,requestId:rid,message:'x'.repeat(3001)}));assert.equal(res.status,400);assert.equal(calls.length,0);
 res=await handle(request(undefined,''));assert.equal(res.status,401);
 console.log('R95 edge: authenticated ownership, N dialogue, history/memory, configured model, bounded response, usage, private keys, cached/pending no-charge retries, fallback and invalid/rate-limited requests passed');
})().catch(e=>{console.error(e);process.exitCode=1});
