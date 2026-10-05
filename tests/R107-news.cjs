const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),{stripTypeScriptTypes}=require('node:module');
const source=fs.readFileSync(__dirname+'/../supabase/functions/current-dilemmas/index.ts','utf8');
const today=new Date().toISOString().slice(0,10),url=`https://www.rtve.es/noticias/${today.replaceAll('-','')}/noticia-verificada/123456.shtml`;
const summary='Una noticia publicada de prueba plantea un conflicto entre proteger la intimidad y compartir información necesaria para pedir ayuda.';
const rss=`<rss><channel><item><title>Noticia publicada de prueba</title><link>${url}</link><pubDate>${new Date().toUTCString()}</pubDate><description><![CDATA[<p>${summary}</p>]]></description></item></channel></rss>`;
const article=`<html><script type="application/ld+json">${JSON.stringify({'@type':'NewsArticle',headline:'Noticia publicada de prueba',datePublished:today,articleBody:summary})}</script><article><p>${summary}</p></article></html>`;
const draft={source_index:0,question:'¿Guardas el secreto o lo cuentas para pedir ayuda?',option_a:'Guardar el secreto',option_b:'Pedir ayuda',twist:'La responsabilidad cambia.',cost_a:'Seguridad',cost_b:'Confianza',theme:'¿LO CUENTAS?'};
async function fixture({feedsFail=false,articleFail=false,unknownIndex=false,aiFail=false}={}){
 let handler,requests=[],aiCalls=0;
 const context=vm.createContext({URL,Response,Request,AbortSignal,Date,console,Deno:{env:{get:k=>k==='SUPABASE_URL'?'https://fixture.supabase.co':'test-key'},serve:f=>handler=f},fetch:async(raw,options={})=>{
  const path=String(raw),body=options.body?JSON.parse(options.body):null;requests.push({path,body});let data;
  if(path.includes('/rss/')||path.includes('feeds.bbci'))return new Response(feedsFail?'unavailable':rss,{status:feedsFail?503:200});
  if(path===url)return new Response(articleFail?'unavailable':article,{status:articleFail?503:200});
  if(path.endsWith('/auth/v1/user'))data={id:'test-user'};
  else if(path.includes('api.openai.com')){
   aiCalls++;if(aiFail)return Response.json({error:{code:'unavailable'}},{status:503});
   if(body.tools)data={output:[{type:'web_search_call',status:'completed',action:{type:'open_page',url}},{type:'message',content:[{type:'output_text',text:'Real searched article'}]}]};
   else data={output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(body.text.format.name==='grounded_news_facts'?{stories:[{source_index:unknownIndex?99:0,summary,conflict:'Privacidad y protección'}]}:{dilemmas:[draft]})}]}]};
  }
  else if(path.endsWith('rpc/claim_current_ai'))data={status:'claimed',lease:'fixture-lease'};
  else if(path.endsWith('rpc/finish_current_ai'))data=[101];
  else if(path.endsWith('rpc/fallback_current_ai'))data={ids:[202],fallback:'catalog'};
  else if(path.endsWith('rpc/fresh_world_candidates'))data={ids:body.p_ids};
  else if(path.includes('dilemmas?id=in.'))data=[{id:101,news_meta:{date:today,url}}];else data=[];
  return Response.json(data);
 }});
 vm.runInContext(stripTypeScriptTypes(source),context);
 assert.equal(context.feedItems(rss,new Date()).length,1);
 assert.equal(context.feedItems(rss.replace(new Date().toUTCString(),'Wed, 01 Jan 2020 10:00:00 GMT'),new Date()).length,0,'Stale RSS rejected');
 assert.equal(context.feedItems(rss.replace(url,'https://evil.example/article'),new Date()).length,0,'Source allowlist enforced');
 assert.equal(context.articleSource(article,url,new Date()).date,today);
 assert.equal(context.validNews([{title:'False article',date:today,url:'https://www.rtve.es/noticias/',summary}],new Date()).length,0,'Homepages rejected');
 const response=await handler(new Request('https://fixture/current-dilemmas',{method:'POST',headers:{authorization:'Bearer test-token',origin:'https://xtronzio.github.io'},body:JSON.stringify({intensity:3,theme:'ALEATORIO'})}));
 assert.equal(response.status,200);assert.equal((await response.json()).status,'ready');
 const finish=requests.find(x=>x.path.endsWith('rpc/finish_current_ai'));
 if(unknownIndex||aiFail){assert.equal(finish,undefined,'Invalid news must never be published');assert(requests.some(x=>x.path.endsWith('rpc/fallback_current_ai')))}
 else{assert.equal(finish.body.p_rows[0].news_meta.url,url,'Publisher URL preserved');assert.equal(finish.body.p_rows[0].news_meta.date,today);assert.equal(finish.body.p_rows[0].news_meta.selection_policy,'grounded-publishers-v3');assert.equal(aiCalls,feedsFail?3:2);assert(!requests.some(x=>x.path.endsWith('rpc/fallback_current_ai')));assert(requests.some(x=>x.path.endsWith('rpc/remember_world_dilemma')))}
 assert.match(requests.find(x=>x.path.endsWith('rpc/claim_current_ai')).body.p_key,/^v3-publishers:3:ALEATORIO:\d{4}-\d{2}-\d{2}$/);
 return context;
}
(async()=>{await fixture();await fixture({articleFail:true});await fixture({feedsFail:true});await fixture({unknownIndex:true});await fixture({aiFail:true});console.log('PASS R107 news: dated publisher feeds, article context, Spanish source priority, fixed source IDs/URLs/dates, stale/untrusted/homepage rejection, unavailable article/feed recovery, web-source fallback, invalid model ID rejection, provider failure fallback and private display history')})().catch(e=>{console.error(e);process.exitCode=1});
