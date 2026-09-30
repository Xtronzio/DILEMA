alter table public.dilemmas add column if not exists source_kind text not null default 'catalog';
alter table public.dilemmas add column if not exists news_meta jsonb;
alter table public.private_dilemma_sessions add column if not exists news_meta jsonb;
alter table public.debate_selections drop constraint debate_selections_phase_check;
alter table public.debate_selections add constraint debate_selections_phase_check check(phase in ('filters','questions','runoff','random','finished','news_loading'));
create table if not exists public.current_ai_cache(cache_key text primary key, status text not null, lease uuid, lease_until timestamptz, expires_at timestamptz, dilemma_ids jsonb not null default '[]', usage jsonb, updated_at timestamptz not null default now());
alter table public.current_ai_cache enable row level security;
revoke all on public.current_ai_cache from anon,authenticated;
grant all on public.current_ai_cache to service_role;
create table if not exists public.current_ai_budget(day date not null, owner text not null, calls integer not null default 0, primary key(day,owner));
alter table public.current_ai_budget enable row level security;
revoke all on public.current_ai_budget from anon,authenticated;
grant all on public.current_ai_budget to service_role;
create or replace function private.claim_current_ai(p_key text,p_user uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.current_ai_cache; ticket uuid; n integer;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 if p_key !~ '^v1:[123]:' or length(p_key)>100 or p_user is null then raise exception 'Invalid key';end if;
 perform pg_advisory_xact_lock(hashtextextended('current-ai-budget',0));
 select * into c from public.current_ai_cache where cache_key=p_key for update;
 if c.status='ready' and c.expires_at>now() then return jsonb_build_object('status','ready','ids',c.dilemma_ids);end if;
 if c.lease_until>now() then return jsonb_build_object('status','pending');end if;
 select calls into n from public.current_ai_budget where day=current_date and owner='global';
 if coalesce(n,0)>=30 then return jsonb_build_object('status','limited');end if;
 select calls into n from public.current_ai_budget where day=current_date and owner=p_user::text;
 if coalesce(n,0)>=6 then return jsonb_build_object('status','limited');end if;
 insert into public.current_ai_budget(day,owner,calls) values(current_date,'global',1),(current_date,p_user::text,1) on conflict(day,owner) do update set calls=public.current_ai_budget.calls+1;
 ticket:=gen_random_uuid();
 insert into public.current_ai_cache(cache_key,status,lease,lease_until) values(p_key,'building',ticket,now()+interval '100 seconds') on conflict(cache_key) do update set status='building',lease=ticket,lease_until=now()+interval '100 seconds',updated_at=now();
 return jsonb_build_object('status','claimed','lease',ticket);
end $$;
revoke all on function private.claim_current_ai(text,uuid) from public,anon,authenticated;
grant execute on function private.claim_current_ai(text,uuid) to service_role;
create or replace function public.claim_current_ai(p_key text,p_user uuid) returns jsonb language sql security invoker set search_path='' as $$ select private.claim_current_ai(p_key,p_user) $$;
revoke all on function public.claim_current_ai(text,uuid) from public,anon,authenticated;
grant execute on function public.claim_current_ai(text,uuid) to service_role;
create or replace function private.publish_current_ai(p_room bigint,p_stage integer,p_ids jsonb) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 if jsonb_array_length(p_ids)<>3 or exists(select 1 from jsonb_array_elements_text(p_ids) x where not exists(select 1 from public.dilemmas d where d.id=x::bigint and d.source_kind='current' and d.active)) then raise exception 'Invalid candidates';end if;
 update public.debate_selections s set phase='questions',options=p_ids,updated_at=now() where s.room_id=p_room and s.stage=p_stage and s.phase='news_loading' and exists(select 1 from public.rooms r where r.id=p_room and r.status='waiting');
 return found;
end $$;
revoke all on function private.publish_current_ai(bigint,integer,jsonb) from public,anon,authenticated;
grant execute on function private.publish_current_ai(bigint,integer,jsonb) to service_role;
create or replace function public.publish_current_ai(p_room bigint,p_stage integer,p_ids jsonb) returns boolean language sql security invoker set search_path='' as $$ select private.publish_current_ai(p_room,p_stage,p_ids) $$;
revoke all on function public.publish_current_ai(bigint,integer,jsonb) from public,anon,authenticated;
grant execute on function public.publish_current_ai(bigint,integer,jsonb) to service_role;
create or replace function private.current_ai_round_context() returns trigger language plpgsql security definer set search_path='' as $$
declare meta jsonb;
begin
 select news_meta into meta from public.dilemmas where id=new.dilemma_id;
 if meta is not null then new.context:=concat_ws(E'\n\n',nullif(new.context,''),'INSPIRADO EN ACTUALIDAD. La situación del dilema es hipotética; no atribuyas sus acciones a personas reales. Hechos publicados: '||(meta->>'summary')||' Fuente: '||(meta->>'url')||' Fecha: '||(meta->>'date'));end if;
 return new;
end $$;
revoke all on function private.current_ai_round_context() from public,anon,authenticated;
drop trigger if exists current_ai_context on public.rounds;
create trigger current_ai_context before insert on public.rounds for each row execute function private.current_ai_round_context();

CREATE OR REPLACE FUNCTION public.debate_choose(p_room bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.debate_selections; r public.rooms; option_ids text[]; ranked text[]; tied text[]; winner text; selected_theme text; selected_intensity int; eligible bigint[]; candidate bigint; total int; voted int; rank_n int; rank_next int; d public.dilemmas; host_user uuid;
begin
 select * into s from public.debate_selections where room_id=p_room for update;
 select * into r from public.rooms where id=p_room;
 if s.room_id is null or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Selección cerrada';end if;
 if s.phase not in ('filters','questions','runoff') then raise exception 'Selección cerrada';end if;
 if s.phase='filters' then
  selected_intensity:=split_part(p_choice,'|',1)::int;
  selected_theme:=split_part(p_choice,'|',2);
  if selected_theme like 'ACTUALIDAD IA:%' and substring(selected_theme from 15) not in('¿A QUIÉN SALVAS?','¿LO CUENTAS?','¿TRAICIONAS?','¿TE METES?','¿QUÉ SACRIFICAS?','¿ACEPTAS EL TRATO?','ALEATORIO') then raise exception 'Categoría inválida';end if;
  if selected_intensity not in(1,2,3) or (selected_theme not like 'ACTUALIDAD IA:%' and selected_theme not in('¿A QUIÉN SALVAS?','¿LO CUENTAS?','¿TRAICIONAS?','¿TE METES?','¿QUÉ SACRIFICAS?','¿ACEPTAS EL TRATO?','ALEATORIO')) then raise exception 'Opción inválida'; end if;
  if selected_theme not like 'ACTUALIDAD IA:%' and not exists(select 1 from public.dilemmas where source_kind='catalog' and audience='teen' and active=true and intensity<=selected_intensity and (selected_theme='ALEATORIO' or debate_theme=selected_theme)) then raise exception 'No hay dilemas en esta categoría e intensidad'; end if;
 else
  if not exists(select 1 from jsonb_array_elements_text(s.options) x where x=p_choice) then raise exception 'Dilema fuera de la selección'; end if;
 end if;
 insert into public.debate_selection_votes(room_id,stage,user_id,choice) values(p_room,s.stage,auth.uid(),p_choice);
 select count(*) into total from public.players where room_id=p_room and abandoned_at is null and presence='present';
 select count(*) into voted from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present';
 if voted<total then return public.debate_selection_state(p_room);end if;
 select count(*) into rank_n from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice order by count(*) desc limit 1;
 select array_agg(choice order by random()) into ranked from
 (select v.choice,count(*) as n from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice order by n desc) q;
 select array_agg(choice order by random()) into tied from
 (select v.choice from public.debate_selection_votes v join public.players p on p.room_id=v.room_id and p.user_id=v.user_id where v.room_id=p_room and v.stage=s.stage and p.abandoned_at is null and p.presence='present' group by v.choice having count(*)=rank_n) q;
 if s.phase='runoff' then
  winner:=case when cardinality(tied)=1 then tied[1] else tied[1+floor(random()*cardinality(tied))::int] end;
 elsif cardinality(tied)=1 then winner:=tied[1];
 else
  update public.debate_selections set phase='runoff',stage=s.stage+1,options=to_jsonb(tied[1:2]),updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
 if s.phase='filters' or (s.phase='runoff' and s.theme is null) then
  selected_intensity:=split_part(winner,'|',1)::int;
  selected_theme:=split_part(winner,'|',2);
  if selected_theme like 'ACTUALIDAD IA:%' then
   update public.debate_selections set phase='news_loading',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options='[]'::jsonb,updated_at=now() where room_id=p_room;
   return public.debate_selection_state(p_room);
  end if;
  if selected_theme='ALEATORIO' then
   update public.debate_selections set phase='random',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options='[]'::jsonb,updated_at=now() where room_id=p_room;
   return public.debate_selection_state(p_room);
  end if;
  select array_agg(id order by random()) into eligible from public.dilemmas where source_kind='catalog' and audience='teen' and active=true and intensity<=selected_intensity and debate_theme=selected_theme;
  if eligible is null then raise exception 'No quedan dilemas'; end if;
  update public.debate_selections set phase='questions',stage=s.stage+1,intensity=selected_intensity,theme=selected_theme,options=to_jsonb(eligible[1:least(4,cardinality(eligible))]),updated_at=now() where room_id=p_room;
  return public.debate_selection_state(p_room);
 end if;
 candidate:=winner::bigint;
 select * into d from public.dilemmas where id=candidate and active=true;
 if d.id is null then raise exception 'Dilema no disponible'; end if;
 insert into public.rounds(room_id,round_number,dilemma_id,status,started_at)
 values(p_room,coalesce((select max(round_number) from public.rounds where room_id=p_room),0)+1,candidate,'voting',now());
 update public.rooms set status='playing' where id=p_room and status='waiting';
 update public.debate_selections set phase='finished',stage=s.stage+1,options='[]'::jsonb,updated_at=now() where room_id=p_room;
 return jsonb_build_object('phase','finished');
end $function$
;
CREATE OR REPLACE FUNCTION public.debate_random_next(p_room bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.rooms; s public.debate_selections; d public.dilemmas; new_id bigint;
begin
 select * into r from public.rooms where id=p_room for update;
 select * into s from public.debate_selections where room_id=p_room;
 if r.status<>'waiting' or r.mode<>'debate' or s.phase<>'random' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede pedir otro dilema'; end if;
 if exists(select 1 from public.rounds where room_id=p_room and id>s.last_round_id) then raise exception 'Inicia una nueva selección desde el hall'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 select * into d from public.dilemmas where source_kind='catalog' and audience='teen' and active=true and intensity<=s.intensity
 and id not in(select dilemma_id from public.debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null and created_at>=s.updated_at)
 order by random() limit 1;
 if d.id is null then raise exception 'No quedan dilemas aleatorios para esta intensidad'; end if;
 insert into public.debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by)
 values(p_room,d.id,d.question,d.option_a,d.option_b,d.category,auth.uid()) returning id into new_id;
 return new_id;
end $function$
;

alter table public.current_ai_cache add column if not exists error_detail text;
create or replace function private.finish_current_ai(p_key text,p_lease uuid,p_rows jsonb,p_usage jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.current_ai_cache; d jsonb; new_id bigint; ids jsonb:='[]';
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 select * into c from public.current_ai_cache where cache_key=p_key for update;
 if c.lease is distinct from p_lease or c.status<>'building' then raise exception 'Obsolete generation';end if;
 if jsonb_array_length(p_rows)<>3 then raise exception 'Invalid candidates';end if;
 for d in select * from jsonb_array_elements(p_rows) loop
  if d->>'source_kind'<>'current' or d->>'audience'<>'teen' or d->'news_meta' is null then raise exception 'Invalid candidate';end if;
  insert into public.dilemmas(audience,category,intensity,debate_theme,question,option_a,option_b,active,source_kind,news_meta)
  values('teen','ACTUALIDAD IA',(d->>'intensity')::int,d->>'debate_theme',d->>'question',d->>'option_a',d->>'option_b',true,'current',d->'news_meta') returning id into new_id;
  insert into public.dilemma_twists(dilemma_id,text,pressure,active) values(new_id,d->'news_meta'->>'twist','LATERAL',true);
  ids:=ids||jsonb_build_array(new_id);
 end loop;
 update public.current_ai_cache set status='ready',dilemma_ids=ids,usage=p_usage,expires_at=now()+interval '6 hours',lease_until=null,error_detail=null,updated_at=now() where cache_key=p_key;
 return ids;
end $$;
revoke all on function private.finish_current_ai(text,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function private.finish_current_ai(text,uuid,jsonb,jsonb) to service_role;
create or replace function public.finish_current_ai(p_key text,p_lease uuid,p_rows jsonb,p_usage jsonb) returns jsonb language sql security invoker set search_path='' as $$ select private.finish_current_ai(p_key,p_lease,p_rows,p_usage) $$;
revoke all on function public.finish_current_ai(text,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.finish_current_ai(text,uuid,jsonb,jsonb) to service_role;
