const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
const source=stripTypeScriptTypes(fs.readFileSync(process.argv[2]||'supabase/functions/debate-coach/index.ts','utf8'));
let handler,calls=[],saved=true,prepared;
const ctx={Deno:{env:{get:name=>name==='SUPABASE_URL'?'https://example.invalid':name==='SUPABASE_ANON_KEY'?'test-key':undefined},serve:fn=>{handler=fn}},Response,Request,AbortSignal,console,fetch:async(url,options)=>{
 const name=url.split('/').at(-1),body=JSON.parse(options.body);calls.push({name,body});
 if(name==='prepare_debate_assistant')return new Response(JSON.stringify(prepared));
 if(name==='save_debate_assistant_context')return new Response(JSON.stringify(saved));
 throw Error('Unexpected external call: '+url);
}};
vm.createContext(ctx);vm.runInContext(source,ctx);
const request=()=>new Request('https://example.invalid',{method:'POST',headers:{authorization:'Bearer test-session','content-type':'application/json'},body:JSON.stringify({roundId:81})});
(async()=>{
 prepared={question:'¿Lo cuentas?',option_a:'Sí',option_b:'No',choice:'A',cycle:1,source:'token',status:'ready',mode:'IA',context_signature:'approved-hash',guide:{version:2,rutas:[]}};
 let res=await handler(request()),body=await res.json();assert.equal(res.status,200);assert.equal(body.cached,true);assert.equal(body.context_signature,'approved-hash');assert.equal(calls.length,1);
 prepared={...prepared,status:'draft',context:'CONTEXTO VALIDADO',guide:null};calls=[];
 res=await handler(request());body=await res.json();assert.equal(res.status,200);assert.equal(body.cached,false);assert.equal(body.context_signature,'approved-hash');assert.equal(calls[1].name,'save_debate_assistant_context');assert.equal(calls[1].body.p_signature,'approved-hash');
 saved=false;res=await handler(request());body=await res.json();assert.equal(res.status,409);assert.ok(body.error.includes('contexto'));assert.equal(body.guide,undefined);
 console.log('PASS R81 coach: cached and new guides carry approved context signature; stale generation rejected; no real AI calls');
})();
