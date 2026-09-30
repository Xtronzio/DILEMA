import { createClient } from "npm:@supabase/supabase-js@2.95.3";
const allowedOrigin="https://xtronzio.github.io";
const headers={"content-type":"application/json; charset=utf-8","cache-control":"no-store","access-control-allow-origin":allowedOrigin,"access-control-allow-headers":"authorization, apikey, content-type, x-client-info","access-control-allow-methods":"POST, OPTIONS","vary":"Origin"};
const answer=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
const tokenPattern=/^dl1_[A-Za-z0-9_-]{43}$/;
async function digest(token:string){const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token));return Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('')}
function randomToken(){const b=crypto.getRandomValues(new Uint8Array(32));return 'dl1_'+btoa(String.fromCharCode(...b)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'')}
function profiles(value:unknown){
 if(!Array.isArray(value)||value.length>50)throw Error('BAD_PROFILES');
 const result=value.map((p:any)=>{
  if(typeof p?.id!=='string'||!/^[A-Za-z0-9_-]{1,80}$/.test(p.id)||typeof p.name!=='string'||!p.name.trim()||p.name.length>16||typeof p.avatar!=='string'||p.avatar.length>200||typeof p.motto!=='string'||p.motto.length>50)throw Error('BAD_PROFILES');
  return {id:p.id,name:p.name,avatar:p.avatar,motto:p.motto};
 });if(JSON.stringify(result).length>30000)throw Error('BAD_PROFILES');return result;
}
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin');if(origin&&origin!==allowedOrigin)return answer({error:'NOT_ALLOWED'},403);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return answer({error:'METHOD'},405);
 try{
  const raw=await req.text();if(raw.length>34000)return answer({error:'TOO_LARGE'},413);
  const body=JSON.parse(raw);const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  if(body.action==='restore'){
   if(typeof body.token!=='string'||!tokenPattern.test(body.token))return answer({error:'INVALID_LINK'},403);
   const {data:link,error:lookup}=await admin.rpc('access_link_read',{p_hash:await digest(body.token)});
   if(lookup)return answer({error:lookup.message.includes('TRY_LATER')?'TRY_LATER':'UNAVAILABLE'},lookup.message.includes('TRY_LATER')?429:503);
   if(!link?.user_id)return answer({error:'INVALID_LINK'},403);
   const {data:owner,error:ownerError}=await admin.auth.admin.getUserById(link.user_id);
   if(ownerError||!owner.user?.email)return answer({error:'UNAVAILABLE'},503);
   const {data:magic,error:magicError}=await admin.auth.admin.generateLink({type:'magiclink',email:owner.user.email});
   if(magicError||magic.user?.id!==link.user_id||!magic.properties?.hashed_token)return answer({error:'UNAVAILABLE'},503);
   const login=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
   const {data:verified,error:verifyError}=await login.auth.verifyOtp({token_hash:magic.properties.hashed_token,type:'email'});
   if(verifyError||!verified.session||verified.user?.id!==link.user_id)return answer({error:'UNAVAILABLE'},503);
   return answer({session:{access_token:verified.session.access_token,refresh_token:verified.session.refresh_token},user_id:link.user_id,profiles:link.profiles});
  }
  // Create, renew and sync always require a verified user JWT; a publishable key is insufficient.
  const bearer=req.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];if(!bearer)return answer({error:'AUTH_REQUIRED'},401);
  const {data:authenticated,error:authError}=await admin.auth.getUser(bearer);
  if(authError||!authenticated.user)return answer({error:'AUTH_REQUIRED'},401);
  const owner=authenticated.user;
  if(body.action==='sync'){
   const {error}=await admin.rpc('access_link_profiles',{p_user:owner.id,p_profiles:profiles(body.profiles)});
   return error?answer({error:'UNAVAILABLE'},503):answer({ok:true});
  }
  if(body.action!=='copy'&&body.action!=='renew')return answer({error:'BAD_ACTION'},400);
  const list=profiles(body.profiles);
  if(!owner.email){
   // An internal, non-deliverable address allows standard Auth sessions on the original UUID.
   // No email is sent and no password is assigned. Access requires the random recovery token.
   const {error}=await admin.auth.admin.updateUserById(owner.id,{email:owner.id+'@access.dilema.invalid',email_confirm:true});
   if(error)return answer({error:'UNAVAILABLE'},503);
  }
  const token=body.action==='copy'&&typeof body.token==='string'&&tokenPattern.test(body.token)?body.token:randomToken();
  const {error}=await admin.rpc('access_link_write',{p_user:owner.id,p_hash:await digest(token),p_profiles:list,p_replace:body.action==='renew'});
  if(error)return answer({error:error.message.includes('LINK_EXISTS')?'LINK_EXISTS':'UNAVAILABLE'},error.message.includes('LINK_EXISTS')?409:503);
  return answer({token});
 }catch(e){return answer({error:e instanceof Error&&e.message==='BAD_PROFILES'?'BAD_PROFILES':'UNAVAILABLE'},400)}
});
