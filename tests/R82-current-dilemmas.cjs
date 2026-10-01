const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
const source=stripTypeScriptTypes(fs.readFileSync(process.argv[2]||'/tmp/r82-news.ts','utf8'));
let handler,calls=[];
const context={Deno:{env:{get:name=>({SUPABASE_URL:'https://database.invalid',SUPABASE_ANON_KEY:'public-test',SUPABASE_SERVICE_ROLE_KEY:'private-test'})[name]},serve:h=>handler=h},Response,Request,URL,AbortSignal,Date,Set,console,fetch:async(url,options={})=>{
 const body=options.body?JSON.parse(options.body):null;calls.push({url,body});
 let data;if(url.endsWith('/auth/v1/user'))data={id:'TEST-USER'};
 else if(url.includes('rpc/debate_selection_state'))data={phase:'news_loading',intensity:3,theme:'ACTUALIDAD IA:ALEATORIO',stage:7};
 else if(url.includes('rpc/claim_current_ai'))data={status:'ready',ids:[11,12]};
 else if(url.includes('rpc/fallback_current_ai'))data={ids:[11],fallback:'previous_news'};
 else if(url.includes('rpc/fresh_world_candidates'))data={ids:[99],fallback:'catalog'};
 else if(url.includes('rpc/publish_current_ai'))data=true;
 else if(url.includes('/dilemmas?id='))data=[{id:99,question:'FRESH'}];
 else throw Error('Unexpected URL '+url);
 return new Response(JSON.stringify(data),{status:200,headers:{'content-type':'application/json'}});
}};
vm.createContext(context);vm.runInContext(source,context);
function req(body,auth=true){return new Request('https://edge.invalid',{method:'POST',headers:{...(auth?{authorization:'Bearer TEST'}:{}),'content-type':'application/json',origin:'https://xtronzio.github.io'},body:JSON.stringify(body)})}
(async()=>{
 let res=await handler(req({intensity:3,theme:'ALEATORIO'})),data=await res.json();assert.equal(res.status,200);assert.equal(data.candidates[0].id,99);assert.equal(data.fallback,'catalog');assert.ok(calls.find(c=>c.url.includes('fresh_world_candidates')).body.p_user==='TEST-USER');
 assert.ok(calls.find(c=>c.url.includes('dilemmas?id=')).url.includes('(99)'));assert.ok(!calls.some(c=>c.url.includes('openai.com')));
 calls=[];res=await handler(req({roomId:42}));data=await res.json();assert.equal(data.status,'ready');const pub=calls.find(c=>c.url.includes('publish_current_ai'));assert.deepEqual(pub.body.p_ids,[99]);assert.equal(pub.body.p_stage,7);assert.equal(calls.find(c=>c.url.includes('fresh_world_candidates')).body.p_room,42);
 calls=[];res=await handler(req({intensity:2,theme:'ALEATORIO',fallback:true}));data=await res.json();assert.equal(data.candidates[0].id,99);assert.equal(data.fallback,'catalog');assert.ok(!calls.some(c=>c.url.includes('claim_current_ai')));
 calls=[];res=await handler(req({intensity:3},false));assert.equal(res.status,401);assert.equal(calls.length,0);
 console.log('PASS R82 Edge: cached/fallback proposals both filter seen conflicts, room publication uses fresh IDs, actual fallback origin, authentication and zero AI requests');
})().catch(e=>{console.error(e);process.exitCode=1});
