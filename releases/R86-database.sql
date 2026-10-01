-- R86. A saved session keeps its original round and all private per-user records.
alter table public.rooms add column if not exists active_round_id bigint;
alter table public.saved_group_dilemmas add column if not exists session_state text not null default 'finished';
alter table public.saved_group_dilemmas add column if not exists session_id bigint;
alter table public.saved_group_dilemmas add column if not exists room_id bigint;

create table private.debate_saved_sessions (
 id bigint generated always as identity primary key,
 room_id bigint not null references public.rooms(id) on delete cascade,
 round_id bigint not null unique references public.rounds(id) on delete cascade,
 owner_id uuid not null references auth.users(id),
 roster jsonb not null,
 status text not null check(status in ('saved','resumed','finished')),
 created_at timestamptz not null default now(),
 resumed_at timestamptz
);
create table private.debate_session_proposals (
 id bigint generated always as identity primary key,
 room_id bigint not null references public.rooms(id) on delete cascade,
 round_id bigint not null references public.rounds(id) on delete cascade,
 kind text not null check(kind in ('save','resume')),
 proposer uuid not null references auth.users(id),
 electorate uuid[] not null,
 status text not null default 'open' check(status in ('open','accepted','rejected','cancelled')),
 created_at timestamptz not null default now()
);
create unique index session_one_open_per_room on private.debate_session_proposals(room_id) where status='open';
create table private.debate_session_votes (
 proposal_id bigint not null references private.debate_session_proposals(id) on delete cascade,
 user_id uuid not null references auth.users(id),
 choice boolean not null,
 primary key(proposal_id,user_id)
);
alter table private.debate_saved_sessions enable row level security;
alter table private.debate_session_proposals enable row level security;
alter table private.debate_session_votes enable row level security;
create policy session_internal_only on private.debate_saved_sessions using(false) with check(false);
create policy session_proposal_internal_only on private.debate_session_proposals using(false) with check(false);
create policy session_vote_internal_only on private.debate_session_votes using(false) with check(false);
revoke all on private.debate_saved_sessions,private.debate_session_proposals,private.debate_session_votes from public,anon,authenticated;

create function private.active_round(p_room bigint) returns bigint language sql security definer set search_path='' as $$
 select coalesce(r.active_round_id,(select max(id) from public.rounds where room_id=p_room and status<>'saved')) from public.rooms r where r.id=p_room
$$;
revoke all on function private.active_round(bigint) from public,anon,authenticated;

create function private.track_active_round() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.rooms set active_round_id=new.id where id=new.room_id;
 return new;
end $$;
revoke all on function private.track_active_round() from public,anon,authenticated;
create trigger track_active_round after insert on public.rounds for each row execute function private.track_active_round();
update public.rooms r set active_round_id=(select max(id) from public.rounds where room_id=r.id);

create function private.protect_active_round() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in ('anon','authenticated') and new.active_round_id is distinct from old.active_round_id then raise exception 'Session transition requires table approval';end if;
 return new;
end $$;
revoke all on function private.protect_active_round() from public,anon,authenticated;
create trigger protect_active_round before update of active_round_id on public.rooms for each row execute function private.protect_active_round();

create function private.session_roster(p_room bigint) returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('user',user_id,'player',player_id,'presence',presence) order by user_id,player_id),'[]'::jsonb)
 from public.players where room_id=p_room and abandoned_at is null
$$;
revoke all on function private.session_roster(bigint) from public,anon,authenticated;

create function private.session_apply(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare q private.debate_session_proposals; r public.rounds; s private.debate_saved_sessions; owner uuid; d public.dilemmas; changed boolean; roster jsonb; n bigint; seq bigint;
begin
 select * into q from private.debate_session_proposals where id=p_id;
 if q.status<>'accepted' then raise exception 'Session not approved';end if;
 select * into r from public.rounds where id=q.round_id for update;
 perform 1 from public.rooms where id=q.room_id for update;
 if q.kind='save' then
  if r.status<>'debate' or r.debate_phase<>'debate' or not r.paused or private.active_round(q.room_id)<>r.id or not exists(select 1 from public.rooms where id=q.room_id and status='playing') then raise exception 'Debate no longer available to save';end if;
  select p.user_id into owner from public.rooms x join public.players p on p.room_id=x.id and p.player_id=x.host_id where x.id=q.room_id and p.abandoned_at is null;
  roster:=private.session_roster(q.room_id);
  insert into private.debate_saved_sessions(room_id,round_id,owner_id,roster,status) values(q.room_id,r.id,owner,roster,'saved')
   on conflict(round_id) do update set owner_id=excluded.owner_id,roster=excluded.roster,status='saved',created_at=now() returning * into s;
  select * into d from public.dilemmas where id=r.dilemma_id;
  insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b,context,guides,choice,session_state,session_id,room_id)
  values(owner,r.id,d.question,d.option_a,d.option_b,r.context,
   coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'choice',g.choice,'guide',g.guide,'mode',g.mode,'created_at',g.created_at,'cycle_number',g.cycle_number) order by g.created_at desc) from public.debate_assistant_guides g where g.round_id=r.id and g.user_id=owner and g.status='ready'),'[]'::jsonb),
   (select choice from public.debate_vote_cycles where round_id=r.id and user_id=owner order by cycle_number desc limit 1),'paused',s.id,q.room_id)
  on conflict(user_id,source_round_id) do update set context=excluded.context,guides=excluded.guides,choice=excluded.choice,session_state='paused',session_id=excluded.session_id,room_id=excluded.room_id;
  update public.rounds set status='saved' where id=r.id;
  update private.debate_admission_settings set enabled=false where room_id=q.room_id;
  update private.debate_admissions set status='cancelled',decided_at=now() where round_id=r.id and status in('open','queued');
  delete from public.debate_selections where room_id=q.room_id;
  update public.rooms set status='waiting',active_round_id=null where id=q.room_id;
 else
  select * into s from private.debate_saved_sessions where round_id=r.id and room_id=q.room_id and status='saved' for update;
  if s.id is null or r.status<>'saved' or not exists(select 1 from public.rooms where id=q.room_id and status='waiting') then raise exception 'Saved session unavailable';end if;
  if exists(select 1 from public.debate_selections where room_id=q.room_id and phase<>'finished') or exists(select 1 from public.debate_dilemma_proposals where room_id=q.room_id and status in ('open','accepted')) then raise exception 'Finish current selection first';end if;
  changed:=s.roster is distinct from private.session_roster(q.room_id);
  update public.rooms set status='playing',active_round_id=r.id where id=q.room_id;
  update public.rounds set status='debate',paused=false,debate_phase=case when changed then 'twist' else 'debate' end where id=r.id;
  if changed then
   -- Approval to resume with a different roster also approves a fresh ballot.
   select coalesce(max(proposal_number),0)+1 into seq from public.debate_revote_proposals where round_id=r.id and vote_cycle=r.vote_cycle;
   insert into public.debate_revote_proposals(round_id,vote_cycle,proposal_number,status) values(r.id,r.vote_cycle,seq,'accepted');
   insert into public.debate_events(id,round_id,event_type,text) values((extract(epoch from clock_timestamp())*1000000)::bigint,r.id,'system','LA MESA HA CAMBIADO. ABRIMOS UNA NUEVA VOTACIÓN; EL DILEMA, LOS GIROS Y EL CONTEXTO SE CONSERVAN.');
  end if;
  update private.debate_saved_sessions set status='resumed',resumed_at=now() where id=s.id;
  update public.saved_group_dilemmas set session_state='resumed' where source_round_id=r.id and session_id=s.id;
 end if;
end $$;
revoke all on function private.session_apply(bigint) from public,anon,authenticated;

create function private.session_state(p_room bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare q private.debate_session_proposals; me uuid:=auth.uid(); n bigint;y bigint;z bigint;mine boolean;items jsonb;present boolean; room public.rooms;
begin
 select * into room from public.rooms where id=p_room;
 if me is null or not exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null) then raise exception 'Not in room';end if;
 select * into q from private.debate_session_proposals where room_id=p_room and status='open';
 select exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null and presence='present') into present;
 if q.id is not null then
  select count(*) into n from public.players where room_id=p_room and user_id=any(q.electorate) and presence='present' and abandoned_at is null;
  select count(*) filter(where v.choice),count(*) filter(where not v.choice) into y,z from private.debate_session_votes v join public.players p on p.room_id=p_room and p.user_id=v.user_id where v.proposal_id=q.id and p.user_id=any(q.electorate) and p.presence='present' and p.abandoned_at is null;
  if n=0 or q.kind='save' and not exists(select 1 from public.rounds where id=q.round_id and status='debate' and paused and debate_phase='debate') or q.kind='resume' and room.status<>'waiting' then
   update private.debate_session_proposals set status='cancelled' where id=q.id;
  elsif y>n/2 then
   update private.debate_session_proposals set status='accepted' where id=q.id;
   perform private.session_apply(q.id);
  elsif z>=ceil(n/2.0) or y+z>=n then
   update private.debate_session_proposals set status='rejected' where id=q.id;
  end if;
  select * into q from private.debate_session_proposals where id=q.id and status='open';
  if q.id is not null then select choice into mine from private.debate_session_votes where proposal_id=q.id and user_id=me;end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'round_id',s.round_id,'question',d.question,'created_at',s.created_at) order by s.created_at desc),'[]'::jsonb) into items
 from private.debate_saved_sessions s join public.rounds r on r.id=s.round_id join public.dilemmas d on d.id=r.dilemma_id where s.room_id=p_room and s.status='saved';
 return jsonb_build_object('room_status',(select status from public.rooms where id=p_room),'active_round_id',(select active_round_id from public.rooms where id=p_room),'sessions',items,
 'proposal',case when q.id is null then null else jsonb_build_object('id',q.id,'kind',q.kind,'question',(select d.question from public.rounds r join public.dilemmas d on d.id=r.dilemma_id where r.id=q.round_id),'yes',y,'no',z,'players',n,'mine',mine,'can_vote',present and me=any(q.electorate)) end);
end $$;
revoke all on function private.session_state(bigint) from public,anon,authenticated;

create function private.session_action(p_room bigint,p_action text,p_session bigint default null,p_proposal bigint default null,p_vote boolean default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare me uuid:=auth.uid();room public.rooms;r public.rounds;q private.debate_session_proposals;rd bigint;elect uuid[];proposal bigint;before_state jsonb;
begin
 -- Lock the round before the room, matching other debate transitions.
 rd:=case when p_action='resume' then (select round_id from private.debate_saved_sessions where id=p_session and room_id=p_room) else private.active_round(p_room) end;
 if p_action='vote' then select round_id into rd from private.debate_session_proposals where id=p_proposal and room_id=p_room;end if;
 perform 1 from public.rounds where id=rd for update;
 select * into room from public.rooms where id=p_room for update;
 if me is null or not exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null) then raise exception 'Not in room';end if;
 if p_action='state' then return private.session_state(p_room);end if;
 if not exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null and presence='present') then raise exception 'Not present';end if;
 if p_action='vote' then
  before_state:=private.session_state(p_room);
  select * into q from private.debate_session_proposals where id=p_proposal and room_id=p_room and status='open';
  if q.id is null then return before_state||jsonb_build_object('late',true);end if;
  if p_vote is null or not me=any(q.electorate) then raise exception 'Not eligible';end if;
  insert into private.debate_session_votes(proposal_id,user_id,choice) values(q.id,me,p_vote) on conflict do nothing;
  return private.session_state(p_room);
 end if;
 if p_action not in('save','resume') or room.mode<>'debate' then raise exception 'Invalid session action';end if;
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'Another decision is open';end if;
 select * into r from public.rounds where id=rd;
 if p_action='save' then
  perform private.context_guard(rd);
  if r.id is null or room.status<>'playing' or r.status<>'debate' or r.debate_phase<>'debate' or not r.paused then raise exception 'Pause the debate before saving';end if;
  if exists(select 1 from public.debate_pause_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_presence_requests where round_id=rd and status='open') or exists(select 1 from public.debate_twist_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_revote_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_optional_revote_windows where round_id=rd and closed_at is null) then raise exception 'Resolve pending decision first';end if;
 else
  if r.id is null or r.status<>'saved' or room.status<>'waiting' or not exists(select 1 from private.debate_saved_sessions where id=p_session and room_id=p_room and status='saved') then raise exception 'Saved session unavailable';end if;
  if not exists(select 1 from public.players where room_id=p_room and user_id=me and player_id=room.host_id) then raise exception 'Host proposes resume';end if;
  if exists(select 1 from public.debate_selections where room_id=p_room and phase<>'finished') or exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in('open','accepted')) then raise exception 'Return to hall before resuming';end if;
 end if;
 select array_agg(user_id order by user_id) into elect from public.players where room_id=p_room and presence='present' and abandoned_at is null;
 insert into private.debate_session_proposals(room_id,round_id,kind,proposer,electorate) values(p_room,rd,p_action,me,elect) returning id into proposal;
 insert into private.debate_session_votes(proposal_id,user_id,choice) values(proposal,me,true);
 return private.session_state(p_room);
end $$;
revoke all on function private.session_action(bigint,text,bigint,bigint,boolean) from public,anon;
grant execute on function private.session_action(bigint,text,bigint,bigint,boolean) to authenticated;
create function public.debate_session_action(p_room bigint,p_action text,p_session bigint default null,p_proposal bigint default null,p_vote boolean default null) returns jsonb language sql security invoker set search_path='' as $$
 select private.session_action(p_room,p_action,p_session,p_proposal,p_vote)
$$;
revoke all on function public.debate_session_action(bigint,text,bigint,bigint,boolean) from public,anon;
grant execute on function public.debate_session_action(bigint,text,bigint,bigint,boolean) to authenticated;

-- A stored round is immutable. Only the approved transition may wake it up.
create function private.guard_saved_round() returns trigger language plpgsql security definer set search_path='' as $$
declare rd bigint;
begin
 if tg_table_name='rounds' then
  if old.status='saved' and new.status='saved' then raise exception 'Saved session is frozen';end if;
  if old.status='saved' and new.status<>'saved' and not exists(select 1 from private.debate_session_proposals where round_id=old.id and kind='resume' and status='accepted') then raise exception 'Resume requires table approval';end if;
 else
  rd:=case when tg_op='DELETE' then old.round_id else new.round_id end;
  perform 1 from public.rounds where id=rd for update;
  if exists(select 1 from public.rounds where id=rd and status='saved') then raise exception 'Saved session is frozen';end if;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
revoke all on function private.guard_saved_round() from public,anon,authenticated;
create trigger freeze_saved_round before update on public.rounds for each row when(old.status='saved') execute function private.guard_saved_round();
do $$ declare t record;begin
 for t in select table_schema,table_name from information_schema.columns where column_name='round_id' and table_schema in('public','private') and table_name like 'debate_%' and table_name not in ('debate_saved_sessions','debate_session_proposals','debate_admissions','debate_assistant_guides','debate_private_proclamations','debate_context_requests','debate_limbo_proposals') loop
  execute format('create trigger freeze_saved_session before insert or update on %I.%I for each row execute function private.guard_saved_round()',t.table_schema,t.table_name);
 end loop;
end $$;


CREATE OR REPLACE FUNCTION public.abandon_debate(p_room_id bigint, p_farewell text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me text;v_host text;v_new_host text;v_round bigint;v_msg text;v_event_id bigint;
begin
 select player_id into v_me from players where room_id=p_room_id and user_id=auth.uid() and abandoned_at is null order by created_at desc limit 1;
 if v_me is null then raise exception 'Player not found'; end if;
 select host_id into v_host from rooms where id=p_room_id;
 v_msg:=nullif(trim(coalesce(p_farewell,'')),'');
 if v_msg is not null and length(v_msg)>120 then raise exception 'Farewell too long'; end if;
 v_round:=private.active_round(p_room_id);
 if v_msg is not null and v_round is not null then
   v_event_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
   insert into debate_events(id,round_id,event_type,text) values(v_event_id,v_round,'farewell','MENSAJE DE DESPEDIDA · '||v_msg);
 end if;
 if v_host=v_me then
   select player_id into v_new_host from players where room_id=p_room_id and abandoned_at is null and player_id<>v_me order by case when presence='present' then 0 else 1 end,created_at limit 1;
   if v_new_host is not null then update rooms set host_id=v_new_host where id=p_room_id; end if;
 end if;
 update players set abandoned_at=now(),presence='absent',farewell=v_msg where room_id=p_room_id and player_id=v_me and abandoned_at is null;
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_choose(p_room bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.debate_selections; r public.rooms; option_ids text[]; ranked text[]; tied text[]; winner text; selected_theme text; selected_intensity int; eligible bigint[]; candidate bigint; total int; voted int; rank_n int; rank_next int; d public.dilemmas; host_user uuid;
begin
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'The table must resolve the session proposal first';end if;
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
  if not (p_choice='__DISCARD__' and s.phase='questions' and s.theme like 'ACTUALIDAD IA:%') and not exists(select 1 from jsonb_array_elements_text(s.options) x where x=p_choice) then raise exception 'Dilema fuera de la selección'; end if;
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
 if winner='__DISCARD__' then
  insert into private.world_dilemma_history(scope,conflict_key)
  select 'room:'||p_room::text,private.world_key(x::bigint) from jsonb_array_elements_text(s.options) x where x<>'__DISCARD__' on conflict do nothing;
  insert into private.world_dilemma_history(scope,conflict_key)
  select 'user:'||p.user_id::text,private.world_key(x::bigint) from public.players p cross join jsonb_array_elements_text(s.options) x where p.room_id=p_room and p.abandoned_at is null and p.user_id is not null and x<>'__DISCARD__' on conflict do nothing;
  update public.debate_selections set phase='news_loading',stage=s.stage+1,options='[]'::jsonb,updated_at=now() where room_id=p_room;
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

CREATE OR REPLACE FUNCTION public.restart_debate_to_hall(p_room_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_host text; v_me text;
begin
 select host_id into v_host from rooms where id=p_room_id;
 select player_id into v_me from players where room_id=p_room_id and user_id=auth.uid() and abandoned_at is null limit 1;
 if v_me is null or v_host<>v_me then raise exception 'Host only'; end if;

 delete from debate_close_votes where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from debate_twist_requests where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from debate_events where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from debate_proclamations where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from debate_twists where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from debate_vote_cycles where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from votes where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from round_players where round_id in(select id from rounds where room_id=p_room_id and status<>'saved');
 delete from rounds where room_id=p_room_id and status<>'saved';

 update players set presence='present' where room_id=p_room_id and abandoned_at is null;
 update rooms set status='waiting',mode='debate',active_round_id=null where id=p_room_id;
end $function$
;

CREATE OR REPLACE FUNCTION private.request_admission(p_room bigint, p_player text, p_name text, p_avatar text, p_motto text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rd bigint;rid bigint;
begin
 if auth.uid() is null or length(trim(p_player)) not between 1 and 100 or length(trim(p_name)) not between 1 and 16 or length(p_avatar) not between 1 and 100 or length(coalesce(p_motto,''))>50 then raise exception 'Invalid profile';end if;
 rd:=private.active_round(p_room);
 perform 1 from public.rounds where id=rd for update;
 perform 1 from public.rooms where id=p_room for update;
 if not private.admission_available(p_room) then raise exception 'Admissions closed';end if;
 if exists(select 1 from public.players where room_id=p_room and (user_id=auth.uid() or player_id=p_player)) then raise exception 'Already a member';end if;
 select id into rid from private.debate_admissions where round_id=rd and user_id=auth.uid() and status in('queued','open');
 if rid is not null then return rid;end if;
 insert into private.debate_admissions(round_id,user_id,player_id,name,avatar,motto) values(rd,auth.uid(),p_player,trim(p_name),p_avatar,nullif(trim(p_motto),'')) returning id into rid;
 perform private.admission_pump(rd);return rid;
end $function$
;

CREATE OR REPLACE FUNCTION private.set_admission(p_room bigint, p_enabled boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rd bigint;
begin
 rd:=private.active_round(p_room);
 perform 1 from public.rounds where id=rd for update;
 if auth.uid() is null or not exists(select 1 from public.rooms r join public.players p on p.room_id=r.id and p.player_id=r.host_id where r.id=p_room and r.mode='debate' and r.status='playing' and p.user_id=auth.uid() and p.abandoned_at is null and p.presence='present') then raise exception 'Host only';end if;
 insert into private.debate_admission_settings(room_id,round_id,enabled) values(p_room,rd,p_enabled) on conflict(room_id) do update set round_id=excluded.round_id,enabled=excluded.enabled;
end $function$
;

CREATE OR REPLACE FUNCTION private.admission_available(p_room bigint)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select auth.uid() is not null and exists(select 1 from private.debate_admission_settings s join public.rooms r on r.id=s.room_id join public.rounds rd on rd.id=s.round_id where r.id=p_room and r.status='playing' and r.mode='debate' and s.enabled and rd.debate_phase<>'finished' and rd.id=private.active_round(p_room) and (select count(*) from public.players where room_id=p_room and abandoned_at is null)<20)
$function$
;

CREATE OR REPLACE FUNCTION public.request_abandoned_rejoin(p_room_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.players; r public.rooms; latest_round bigint; open_id bigint;
begin
 if auth.uid() is null then raise exception 'No autenticado';end if;
 select * into r from public.rooms where id=p_room_id;
 select * into p from public.players where room_id=p_room_id and user_id=auth.uid() order by id desc limit 1;
 if r.id is null or r.mode<>'debate' or r.status not in ('waiting','playing') or p.id is null or p.abandoned_at is null or p.presence<>'absent' then raise exception 'Solo quien abandonó puede solicitar volver';end if;
 latest_round:=private.active_round(p_room_id);
 if latest_round is null then raise exception 'Aún no existe un debate para esta sala';end if;
 select id into open_id from public.debate_presence_requests where round_id=latest_round and player_id=p.player_id and status='open' order by id desc limit 1;
 if open_id is not null then return open_id;end if;
 return public.propose_presence_change(latest_round,'return',null);
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_begin_selection(p_room bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.rooms;
begin
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'The table must resolve the session proposal first';end if;
 select * into r from public.rooms where id=p_room for update;
 if r.id is null or r.mode<>'debate' or r.status<>'waiting' or auth.uid() is null or not exists(select 1 from public.players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede iniciar la selección'; end if;
 if exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Hay una propuesta abierta';end if;
 insert into public.debate_selections(room_id,phase,last_round_id) values(p_room,'filters',coalesce((select max(id) from public.rounds where room_id=p_room),0))
 on conflict(room_id) do update set
 phase='filters',stage=public.debate_selections.stage+1,intensity=null,theme=null,options='[]'::jsonb,last_round_id=coalesce((select max(id) from public.rounds where room_id=p_room),0),updated_at=clock_timestamp()
 where public.debate_selections.phase='finished'
 or exists(select 1 from public.rounds where room_id=p_room and id>public.debate_selections.last_round_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.get_abandoned_rejoin_state(p_room_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.players; r public.rooms; latest_round bigint; req public.debate_presence_requests;
begin
 if auth.uid() is null then raise exception 'No autenticado';end if;
 select * into p from public.players where room_id=p_room_id and user_id=auth.uid() order by id desc limit 1;
 select * into r from public.rooms where id=p_room_id;
 if p.id is null or r.id is null or r.mode<>'debate' then raise exception 'No perteneces a esta mesa';end if;
 latest_round:=private.active_round(p_room_id);
 if latest_round is not null then
  select * into req from public.debate_presence_requests where round_id=latest_round and player_id=p.player_id and action='return' order by created_at desc limit 1;
 end if;
 return jsonb_build_object('room_status',r.status,'round_id',latest_round,'presence',p.presence,
  'abandoned',p.abandoned_at is not null,'request_status',req.status,'request_id',req.id);
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_propose_with_context(p_room bigint, p_question text, p_a text, p_b text, p_context text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare id bigint;
begin
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'The table must resolve the session proposal first';end if;
 if length(coalesce(p_context,''))>3000 then raise exception 'Context too long'; end if;
 id:=public.debate_propose_dilemma(p_room,null,p_question,p_a,p_b);
 perform private.context_initial(id,p_context);
 return id;
end $function$
;

CREATE OR REPLACE FUNCTION private.context_guard(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 perform 1 from public.rounds where id=p_round for update;
 if exists(select 1 from public.rounds where id=p_round and status='saved') then raise exception 'Resume the saved session first';end if;
 if exists(select 1 from private.debate_session_proposals sp join public.rounds r on r.room_id=sp.room_id where r.id=p_round and sp.status='open')
 or exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions adm join public.rounds r on r.id=adm.round_id join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where r.id=p_round and r.debate_phase='debate' and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)) then raise exception 'Another proposal must be resolved first';end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admission jsonb;v_limbo jsonb;v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 if exists(select 1 from rounds where id=p_round_id and status='saved') then raise exception 'Saved session is frozen';end if;
 v_limbo:=private.limbo_state(p_round_id);
 v_admission:=private.admission_state(p_round_id);
 select count(*) filter(where abandoned_at is null), count(*) filter(where abandoned_at is null and presence='present'), count(*) filter(where abandoned_at is null and presence='absent'), count(*) filter(where abandoned_at is not null)
 into vtotal,vp,v_absent,v_abandoned from players where room_id=v_room;
 select count(*) filter(where choice='A'),count(*) filter(where choice='B') into va,vb
 from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*) into vr from debate_twist_requests dtr join players p on p.player_id=dtr.player_id and p.room_id=v_room
 where dtr.round_id=p_round_id and dtr.vote_cycle=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where dvc.choice='A'),count(*) filter(where dvc.choice='B') into v_next,v_next_a,v_next_b from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle+1 and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where used_at is not null) into v_pro_assigned,v_pro_used from debate_proclamations where round_id=p_round_id;
 select count(*),count(*) filter(where used_at is not null),coalesce(bool_or(user_id=auth.uid() and used_at is null),false)
 into v_secret_assigned,v_secret_used,v_secret_mine from debate_secret_revotes where round_id=p_round_id;
 if v_close>0 then
   select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no
   from debate_close_votes dcv join players p on p.player_id=dcv.player_id and p.room_id=v_room
   where dcv.round_id=p_round_id and dcv.proposal_number=v_close and p.abandoned_at is null and p.presence='present';
 end if;
 return jsonb_build_object('phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id),'limbo_state',v_limbo,'admission_state',v_admission,'session_state',private.session_state(v_room),'resume_new_vote',exists(select 1 from private.debate_saved_sessions where round_id=p_round_id and status='resumed') and v_phase='twist' and not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle));
end $function$
;

CREATE OR REPLACE FUNCTION private.admission_busy(p_round bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rounds; n bigint;a bigint;b bigint;
begin
 select * into r from public.rounds where id=p_round;
 if r.id is null or r.status<>'debate' or r.debate_phase<>'debate' or r.paused then return true;end if;
 if exists(select 1 from private.debate_session_proposals where room_id=r.room_id and status='open')
 or exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_pause_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_presence_requests where round_id=p_round and status='open')
 or exists(select 1 from public.debate_twist_proposals where round_id=p_round and vote_cycle=r.vote_cycle and status='open')
 or exists(select 1 from public.debate_revote_proposals where round_id=p_round and vote_cycle=r.vote_cycle and status='open')
 or exists(select 1 from public.debate_optional_revote_windows where round_id=p_round and vote_cycle=r.vote_cycle and closed_at is null) then return true;end if;
 select count(*) into n from public.players where room_id=r.room_id and presence='present' and abandoned_at is null;
 select count(*) filter(where v.choice='A'),count(*) filter(where v.choice='B') into a,b from public.debate_vote_cycles v join public.players p on p.room_id=r.room_id and p.player_id=v.player_id where v.round_id=p_round and v.cycle_number=r.vote_cycle and p.presence='present' and p.abandoned_at is null;
 return n>1 and (a=n or b=n) and not exists(select 1 from public.debate_unanimity_decisions where round_id=p_round and vote_cycle=r.vote_cycle and outcome is not null);
end $function$
;

CREATE OR REPLACE FUNCTION private.archive_finished_dilemma()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare owner_id uuid; q public.dilemmas; own_guides jsonb; own_choice text;
begin
 if new.debate_phase is distinct from 'finished' or old.debate_phase='finished' then return new; end if;
 select p.user_id into owner_id from public.rooms r join public.players p on p.room_id=r.id and p.player_id=r.host_id
 where r.id=new.room_id and r.mode='debate' and p.abandoned_at is null limit 1;
 if owner_id is null then return new;end if;
 select * into q from public.dilemmas where id=new.dilemma_id;
 if q.id is null then return new;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'choice',g.choice,'guide',g.guide,'mode',g.mode,'created_at',g.created_at,'cycle_number',g.cycle_number) order by g.created_at desc),'[]'::jsonb)
 into own_guides from public.debate_assistant_guides g where g.round_id=new.id and g.user_id=owner_id and g.status='ready';
 select choice into own_choice from public.debate_vote_cycles where round_id=new.id and user_id=owner_id order by cycle_number desc limit 1;
 insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b,context,guides,choice)
 values(owner_id,new.id,q.question,q.option_a,q.option_b,new.context,own_guides,own_choice)
 on conflict(user_id,source_round_id) do update set context=excluded.context,guides=excluded.guides,choice=excluded.choice,session_state='finished';
 update private.debate_saved_sessions set status='finished' where round_id=new.id;
 update public.saved_group_dilemmas set session_state='finished' where source_round_id=new.id;
 return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.my_admission(p_id bigint, p_cancel boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q private.debate_admissions;r public.rounds; room public.rooms; dilemma public.dilemmas; payload jsonb;
begin
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if q.id is null then raise exception 'Not your request';end if;
 perform 1 from public.rounds where id=q.round_id for update;
 select * into q from private.debate_admissions where id=p_id and user_id=auth.uid();
 if p_cancel then
  if q.status='accepted' and exists(select 1 from public.players where room_id=(select room_id from public.rounds where id=q.round_id) and user_id=auth.uid() and abandoned_at is null) then perform public.abandon_debate((select room_id from public.rounds where id=q.round_id),null);end if;
  update private.debate_admissions set status='cancelled',decided_at=now() where id=p_id and status in('queued','open','accepted');
 end if;
 perform private.admission_pump(q.round_id);
 select * into q from private.debate_admissions where id=p_id;
 select * into r from public.rounds where id=q.round_id;
 if q.status='accepted' and not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and player_id=q.player_id and abandoned_at is null) then return jsonb_build_object('status','removed');end if;
 if q.status='accepted' and r.status='debate' and r.debate_phase='debate' and r.id=private.active_round(r.room_id) then
  select * into room from public.rooms where id=r.room_id and status='playing' and mode='debate';
  select * into dilemma from public.dilemmas where id=r.dilemma_id;
  if room.id is not null and dilemma.id is not null then
   payload:=jsonb_build_object('room',jsonb_build_object('id',room.id,'code',room.code,'host_id',room.host_id,'expected_players',room.expected_players,'status',room.status,'mode',room.mode),
    'round',jsonb_build_object('id',r.id,'room_id',r.room_id,'status',r.status,'dilemma_id',r.dilemma_id,'context',r.context),
    'dilemma',to_jsonb(dilemma),'state',public.get_debate_state(r.id));
  end if;
 end if;
 return coalesce(payload,'{}'::jsonb)||jsonb_build_object('status',q.status,'room_id',r.room_id,'player_id',q.player_id,'round_id',q.round_id);
end $function$
;


create function private.guard_session_selection() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.rooms where id=new.room_id for update;
 if exists(select 1 from private.debate_session_proposals where room_id=new.room_id and status='open') then raise exception 'Resolve the session proposal first';end if;
 return new;
end $$;
revoke all on function private.guard_session_selection() from public,anon,authenticated;
create trigger session_selection_guard before insert or update on public.debate_selections for each row execute function private.guard_session_selection();
create trigger session_round_guard before insert on public.rounds for each row execute function private.guard_session_selection();


-- Follow-up fixes applied in separate migrations.
alter table private.debate_session_proposals add column applied_tx bigint;

CREATE OR REPLACE FUNCTION private.guard_saved_round()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rd bigint;
begin
 if tg_table_name='rounds' then
  if old.status='saved' and new.status='saved' then raise exception 'Saved session is frozen';end if;
  if old.status='saved' and new.status<>'saved' and not exists(select 1 from private.debate_session_proposals where round_id=old.id and kind='resume' and status='accepted' and applied_tx=txid_current()) then raise exception 'Resume requires table approval';end if;
 else
  rd:=case when tg_op='DELETE' then old.round_id else new.round_id end;
  perform 1 from public.rounds where id=rd for update;
  if exists(select 1 from public.rounds where id=rd and status='saved') then raise exception 'Saved session is frozen';end if;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $function$
;

CREATE OR REPLACE FUNCTION private.session_action(p_room bigint, p_action text, p_session bigint DEFAULT NULL::bigint, p_proposal bigint DEFAULT NULL::bigint, p_vote boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me uuid:=auth.uid();room public.rooms;r public.rounds;q private.debate_session_proposals;rd bigint;elect uuid[];proposal bigint;before_state jsonb;
begin
 -- Lock the round before the room, matching other debate transitions.
 rd:=case when p_action='resume' then (select round_id from private.debate_saved_sessions where id=p_session and room_id=p_room) else private.active_round(p_room) end;
 if p_action='state' and exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then select round_id into rd from private.debate_session_proposals where room_id=p_room and status='open';end if;
 if p_action='vote' then select round_id into rd from private.debate_session_proposals where id=p_proposal and room_id=p_room;end if;
 perform 1 from public.rounds where id=rd for update;
 select * into room from public.rooms where id=p_room for update;
 if me is null or not exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null) then raise exception 'Not in room';end if;
 if p_action='state' then return private.session_state(p_room);end if;
 if not exists(select 1 from public.players where room_id=p_room and user_id=me and abandoned_at is null and presence='present') then raise exception 'Not present';end if;
 if p_action='vote' then
  before_state:=private.session_state(p_room);
  select * into q from private.debate_session_proposals where id=p_proposal and room_id=p_room and status='open';
  if q.id is null then return before_state||jsonb_build_object('late',true);end if;
  if p_vote is null or not me=any(q.electorate) then raise exception 'Not eligible';end if;
  insert into private.debate_session_votes(proposal_id,user_id,choice) values(q.id,me,p_vote) on conflict do nothing;
  return private.session_state(p_room);
 end if;
 if p_action not in('save','resume') or room.mode<>'debate' then raise exception 'Invalid session action';end if;
 if exists(select 1 from private.debate_session_proposals where room_id=p_room and status='open') then raise exception 'Another decision is open';end if;
 select * into r from public.rounds where id=rd;
 if p_action='save' then
  perform private.context_guard(rd);
  if r.id is null or room.status<>'playing' or r.status<>'debate' or r.debate_phase<>'debate' or not r.paused then raise exception 'Pause the debate before saving';end if;
  if exists(select 1 from public.debate_pause_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_presence_requests where round_id=rd and status='open') or exists(select 1 from public.debate_twist_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_revote_proposals where round_id=rd and status='open') or exists(select 1 from public.debate_optional_revote_windows where round_id=rd and closed_at is null) then raise exception 'Resolve pending decision first';end if;
 else
  if r.id is null or r.status<>'saved' or room.status<>'waiting' or not exists(select 1 from private.debate_saved_sessions where id=p_session and room_id=p_room and status='saved') then raise exception 'Saved session unavailable';end if;
  if not exists(select 1 from public.players where room_id=p_room and user_id=me and player_id=room.host_id) then raise exception 'Host proposes resume';end if;
  if exists(select 1 from public.debate_selections where room_id=p_room and phase<>'finished') or exists(select 1 from public.debate_dilemma_proposals where room_id=p_room and status in('open','accepted')) then raise exception 'Return to hall before resuming';end if;
 end if;
 select array_agg(user_id order by user_id) into elect from public.players where room_id=p_room and presence='present' and abandoned_at is null;
 insert into private.debate_session_proposals(room_id,round_id,kind,proposer,electorate) values(p_room,rd,p_action,me,elect) returning id into proposal;
 insert into private.debate_session_votes(proposal_id,user_id,choice) values(proposal,me,true);
 return private.session_state(p_room);
end $function$
;

CREATE OR REPLACE FUNCTION private.session_apply(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q private.debate_session_proposals; r public.rounds; s private.debate_saved_sessions; owner uuid; d public.dilemmas; changed boolean; roster jsonb; n bigint; seq bigint;
begin
 select * into q from private.debate_session_proposals where id=p_id;
 if q.status<>'accepted' then raise exception 'Session not approved';end if;
 update private.debate_session_proposals set applied_tx=txid_current() where id=q.id;
 select * into r from public.rounds where id=q.round_id for update;
 perform 1 from public.rooms where id=q.room_id for update;
 if q.kind='save' then
  if r.status<>'debate' or r.debate_phase<>'debate' or not r.paused or private.active_round(q.room_id)<>r.id or not exists(select 1 from public.rooms where id=q.room_id and status='playing') then raise exception 'Debate no longer available to save';end if;
  select p.user_id into owner from public.rooms x join public.players p on p.room_id=x.id and p.player_id=x.host_id where x.id=q.room_id and p.abandoned_at is null;
  roster:=private.session_roster(q.room_id);
  insert into private.debate_saved_sessions(room_id,round_id,owner_id,roster,status) values(q.room_id,r.id,owner,roster,'saved')
   on conflict(round_id) do update set owner_id=excluded.owner_id,roster=excluded.roster,status='saved',created_at=now() returning * into s;
  select * into d from public.dilemmas where id=r.dilemma_id;
  insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b,context,guides,choice,session_state,session_id,room_id)
  values(owner,r.id,d.question,d.option_a,d.option_b,r.context,
   coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'choice',g.choice,'guide',g.guide,'mode',g.mode,'created_at',g.created_at,'cycle_number',g.cycle_number) order by g.created_at desc) from public.debate_assistant_guides g where g.round_id=r.id and g.user_id=owner and g.status='ready'),'[]'::jsonb),
   (select choice from public.debate_vote_cycles where round_id=r.id and user_id=owner order by cycle_number desc limit 1),'paused',s.id,q.room_id)
  on conflict(user_id,source_round_id) do update set context=excluded.context,guides=excluded.guides,choice=excluded.choice,session_state='paused',session_id=excluded.session_id,room_id=excluded.room_id;
  update private.debate_admission_settings set enabled=false where room_id=q.room_id;
  update private.debate_admissions set status='cancelled',decided_at=now() where round_id=r.id and status in('open','queued');
  update public.rounds set status='saved' where id=r.id;
  delete from public.debate_selections where room_id=q.room_id;
  update public.rooms set status='waiting',active_round_id=null where id=q.room_id;
 else
  select * into s from private.debate_saved_sessions where round_id=r.id and room_id=q.room_id and status='saved' for update;
  if s.id is null or r.status<>'saved' or not exists(select 1 from public.rooms where id=q.room_id and status='waiting') then raise exception 'Saved session unavailable';end if;
  if exists(select 1 from public.debate_selections where room_id=q.room_id and phase<>'finished') or exists(select 1 from public.debate_dilemma_proposals where room_id=q.room_id and status in ('open','accepted')) then raise exception 'Finish current selection first';end if;
  changed:=s.roster is distinct from private.session_roster(q.room_id);
  update public.rooms set status='playing',active_round_id=r.id where id=q.room_id;
  update public.rounds set status='debate',paused=false,debate_phase=case when changed then 'twist' else 'debate' end where id=r.id;
  if changed then
   -- Approval to resume with a different roster also approves a fresh ballot.
   select coalesce(max(proposal_number),0)+1 into seq from public.debate_revote_proposals where round_id=r.id and vote_cycle=r.vote_cycle;
   insert into public.debate_revote_proposals(round_id,vote_cycle,proposal_number,status) values(r.id,r.vote_cycle,seq,'accepted');
   insert into public.debate_events(id,round_id,event_type,text) values((extract(epoch from clock_timestamp())*1000000)::bigint,r.id,'system','LA MESA HA CAMBIADO. ABRIMOS UNA NUEVA VOTACIÓN; EL DILEMA, LOS GIROS Y EL CONTEXTO SE CONSERVAN.');
  end if;
  update private.debate_saved_sessions set status='resumed',resumed_at=now() where id=s.id;
  update public.saved_group_dilemmas set session_state='resumed' where source_round_id=r.id and session_id=s.id;
 end if;
end $function$
;

alter policy session_internal_only on private.debate_saved_sessions to service_role;
alter policy session_proposal_internal_only on private.debate_session_proposals to service_role;
alter policy session_vote_internal_only on private.debate_session_votes to service_role;
CREATE OR REPLACE FUNCTION private.guard_saved_round()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rd bigint;
begin
 if tg_table_name='rounds' then
  if tg_op='DELETE' then
   if exists(select 1 from public.rooms where id=old.room_id) then raise exception 'Saved session must be retained';end if;
   return old;
  end if;
  if old.status='saved' and new.status='saved' then raise exception 'Saved session is frozen';end if;
  if old.status='saved' and new.status<>'saved' and not exists(select 1 from private.debate_session_proposals where round_id=old.id and kind='resume' and status='accepted' and applied_tx=txid_current()) then raise exception 'Resume requires table approval';end if;
 else
  rd:=case when tg_op='DELETE' then old.round_id else new.round_id end;
  perform 1 from public.rounds where id=rd for update;
  if exists(select 1 from public.rounds where id=rd and status='saved') then raise exception 'Saved session is frozen';end if;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $function$
;
create trigger freeze_saved_round_delete before delete on public.rounds for each row when(old.status='saved') execute function private.guard_saved_round();
do $$ declare t record;begin for t in select event_object_schema, event_object_table from information_schema.triggers where trigger_name='freeze_saved_session' group by event_object_schema,event_object_table loop execute format('drop trigger freeze_saved_session on %I.%I',t.event_object_schema,t.event_object_table); execute format('create trigger freeze_saved_session before insert or update or delete on %I.%I for each row execute function private.guard_saved_round()',t.event_object_schema,t.event_object_table);end loop;end $$;

