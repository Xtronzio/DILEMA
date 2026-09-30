alter table public.private_dilemma_sessions add column context text not null default '' check (length(context)<=3000);
alter table public.debate_dilemma_proposals add column context text not null default '' check (length(context)<=3000);
alter table public.rounds add column context text not null default '' check (length(context)<=12000);
create schema if not exists private;
create table private.debate_context_requests (
 id bigint generated always as identity primary key,
 round_id bigint not null references public.rounds(id) on delete cascade,
 requester uuid not null references auth.users(id),
 status text not null default 'open' check(status in ('open','approved','published','rejected','cancelled')),
 created_at timestamptz not null default now()
);
create unique index debate_context_one_open on private.debate_context_requests(round_id) where status in ('open','approved');
create table private.debate_context_votes (
 request_id bigint references private.debate_context_requests(id) on delete cascade,
 user_id uuid references auth.users(id), choice boolean not null,
 primary key(request_id,user_id)
);
alter table private.debate_context_requests enable row level security;
alter table private.debate_context_votes enable row level security;
revoke all on private.debate_context_requests,private.debate_context_votes from public,anon,authenticated;

create function private.context_guard(p_round bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 perform 1 from public.rounds where id=p_round for update;
 if exists(select 1 from private.debate_context_requests where round_id=p_round and status in ('open','approved')) then raise exception 'Another proposal must be resolved first'; end if;
end $$;
revoke all on function private.context_guard(bigint) from public,anon,authenticated;

create function private.context_state(p_round bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare room bigint; c text; req private.debate_context_requests; n bigint; y bigint; no_count bigint; myvote boolean;
begin
 select room_id,context into room,c from public.rounds where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 update private.debate_context_requests r set status='cancelled' where round_id=p_round and status in ('open','approved') and not exists(select 1 from public.players where room_id=room and user_id=r.requester and presence='present' and abandoned_at is null);
 select * into req from private.debate_context_requests where round_id=p_round and status in ('open','approved') order by id desc limit 1;
 select count(*) into n from public.players where room_id=room and presence='present' and abandoned_at is null;
 if req.id is null then return jsonb_build_object('context',c,'players',n); end if;
 select count(*) filter(where choice),count(*) filter(where not choice) into y,no_count from private.debate_context_votes v join public.players p on p.room_id=room and p.user_id=v.user_id where v.request_id=req.id and p.presence='present' and p.abandoned_at is null;
 if req.status='open' then
  if y>n/2 then update private.debate_context_requests set status='approved' where id=req.id;req.status:='approved';
  elsif no_count>n/2 or y+no_count>=n then update private.debate_context_requests set status='rejected' where id=req.id;return jsonb_build_object('context',c,'players',n); end if;
 end if;
 select choice into myvote from private.debate_context_votes where request_id=req.id and user_id=auth.uid();
 return jsonb_build_object('context',c,'players',n,'id',req.id,'status',req.status,'mine',myvote,'requester_me',req.requester=auth.uid(),'voted',y+no_count);
end $$;
create function public.debate_context_state(p_round bigint) returns jsonb language sql security invoker set search_path='' as $$select private.context_state(p_round)$$;

create function private.context_request(p_round bigint) returns void language plpgsql security definer set search_path='' as $$
declare r public.rounds; u jsonb; v_id bigint; n bigint;
begin
 select * into r from public.rounds where id=p_round for update;
 if auth.uid() is null or r.debate_phase<>'debate' or r.paused or not exists(select 1 from public.players where room_id=r.room_id and user_id=auth.uid() and presence='present' and abandoned_at is null) then raise exception 'Not active'; end if;
 perform private.context_guard(p_round);
 if exists(select 1 from public.debate_twist_proposals where round_id=p_round and status='open') or exists(select 1 from public.debate_revote_proposals where round_id=p_round and status='open') or exists(select 1 from public.debate_pause_proposals where round_id=p_round and status='open') or exists(select 1 from public.debate_presence_requests where round_id=p_round and status='open') or exists(select 1 from public.debate_optional_revote_windows where round_id=p_round and closed_at is null) then raise exception 'Another proposal must be resolved first'; end if;
 u:=public.get_debate_unanimity_state(p_round);
 if u is not null and (u->>'outcome') is null then raise exception 'Another proposal must be resolved first'; end if;
 insert into private.debate_context_requests(round_id,requester) values(p_round,auth.uid()) returning debate_context_requests.id into v_id;
 insert into private.debate_context_votes values(v_id,auth.uid(),true);
 select count(*) into n from public.players where room_id=r.room_id and presence='present' and abandoned_at is null;
 if n=1 then update private.debate_context_requests set status='approved' where debate_context_requests.id=v_id; end if;
end $$;
create function public.debate_request_context(p_round bigint) returns void language sql security invoker set search_path='' as $$select private.context_request(p_round)$$;

create function private.context_vote(p_round bigint,p_id bigint,p_yes boolean) returns void language plpgsql security definer set search_path='' as $$
declare room bigint; req private.debate_context_requests;
begin
 select room_id into room from public.rounds where id=p_round for update;
 if auth.uid() is null or p_yes is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 select * into req from private.debate_context_requests where id=p_id and round_id=p_round and status='open';
 if req.id is null then raise exception 'Voting closed'; end if;
 insert into private.debate_context_votes values(p_id,auth.uid(),p_yes) on conflict do nothing;
 perform private.context_state(p_round);
end $$;
create function public.debate_vote_context(p_round bigint,p_id bigint,p_yes boolean) returns void language sql security invoker set search_path='' as $$select private.context_vote(p_round,p_id,p_yes)$$;

create function private.context_submit(p_round bigint,p_id bigint,p_text text) returns void language plpgsql security definer set search_path='' as $$
declare room bigint; c text;
begin
 select room_id,context into room,c from public.rounds where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null and presence='present') or not exists(select 1 from private.debate_context_requests where id=p_id and round_id=p_round and requester=auth.uid() and status='approved') then raise exception 'Context not approved'; end if;
 if length(trim(coalesce(p_text,''))) not between 1 and 3000 then raise exception 'Invalid context'; end if;
 c:=concat_ws(E'\n\n',nullif(c,''),trim(p_text));
 if length(c)>12000 then raise exception 'Context limit reached'; end if;
 update public.rounds set context=c where id=p_round;
 update private.debate_context_requests set status='published' where id=p_id;
end $$;
create function public.debate_submit_context(p_round bigint,p_id bigint,p_text text) returns void language sql security invoker set search_path='' as $$select private.context_submit(p_round,p_id,p_text)$$;
create function private.context_cancel(p_round bigint,p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.rounds where id=p_round for update;
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 update private.debate_context_requests set status='cancelled' where id=p_id and round_id=p_round and requester=auth.uid() and status in ('open','approved');
 if not found then raise exception 'Request unavailable'; end if;
end $$;
create function public.debate_cancel_context(p_round bigint,p_id bigint) returns void language sql security invoker set search_path='' as $$select private.context_cancel(p_round,p_id)$$;

create function public.debate_propose_with_context(p_room bigint,p_question text,p_a text,p_b text,p_context text) returns bigint language plpgsql security invoker set search_path='' as $$
declare id bigint;
begin
 if length(coalesce(p_context,''))>3000 then raise exception 'Context too long'; end if;
 id:=public.debate_propose_dilemma(p_room,null,p_question,p_a,p_b);
 perform private.context_initial(id,p_context);
 return id;
end $$;
create function private.context_initial(p_id bigint,p_text text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.debate_dilemma_proposals where id=p_id and proposed_by=auth.uid()) then raise exception 'Not proposal owner'; end if;
 update public.debate_dilemma_proposals set context=trim(coalesce(p_text,'')) where id=p_id;
end $$;
grant usage on schema private to authenticated;
revoke all on function private.context_state(bigint),private.context_request(bigint),private.context_vote(bigint,bigint,boolean),private.context_submit(bigint,bigint,text),private.context_cancel(bigint,bigint),private.context_initial(bigint,text) from public,anon;
grant execute on function private.context_state(bigint),private.context_request(bigint),private.context_vote(bigint,bigint,boolean),private.context_submit(bigint,bigint,text),private.context_cancel(bigint,bigint),private.context_initial(bigint,text) to authenticated;
revoke all on function public.debate_context_state(bigint),public.debate_request_context(bigint),public.debate_vote_context(bigint,bigint,boolean),public.debate_submit_context(bigint,bigint,text),public.debate_cancel_context(bigint,bigint),public.debate_propose_with_context(bigint,text,text,text,text) from public,anon;
grant execute on function public.debate_context_state(bigint),public.debate_request_context(bigint),public.debate_vote_context(bigint,bigint,boolean),public.debate_submit_context(bigint,bigint,text),public.debate_cancel_context(bigint,bigint),public.debate_propose_with_context(bigint,text,text,text,text) to authenticated;

CREATE OR REPLACE FUNCTION public.propose_debate_close(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_num bigint; v_player text; v_players bigint; v_phase text;v_cycle bigint;
begin
 perform private.context_guard(p_round_id);
 select room_id,close_proposal_number+1,debate_phase,vote_cycle into v_room,v_num,v_phase,v_cycle from rounds where id=p_round_id for update;
 if v_phase<>'debate' then raise exception 'Close proposal unavailable'; end if;
 if exists(select 1 from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open')
 or exists(select 1 from debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open')
 or exists(select 1 from debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Another proposal must be resolved first'; end if;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 update rounds set close_proposal_number=v_num,debate_phase='closing',close_proposed_by=auth.uid() where id=p_round_id;
 insert into debate_close_votes(round_id,proposal_number,player_id,user_id,choice) values(p_round_id,v_num,v_player,auth.uid(),'YES');
 select count(*) into v_players from players where room_id=v_room and abandoned_at is null and presence='present';
 if v_players=1 then update rounds set debate_phase='finished',status='finished',twist_request_open=false where id=p_round_id; end if;
 return v_num;
end $function$
;

CREATE OR REPLACE FUNCTION public.propose_debate_pause(p_round_id bigint, p_desired_paused boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_phase text;v_paused boolean;v_player text;v_id bigint;v_players bigint;
begin
 perform private.context_guard(p_round_id);
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused=p_desired_paused then raise exception 'Pause proposal unavailable'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_id from public.debate_pause_proposals where round_id=p_round_id and status='open' limit 1;
 if v_id is not null then raise exception 'Table decision already open'; end if;
 insert into public.debate_pause_proposals(round_id,desired_paused,proposer_id,proposer_user_id)
 values(p_round_id,p_desired_paused,v_player,auth.uid()) returning id into v_id;
 insert into public.debate_pause_votes(proposal_id,player_id,user_id,choice) values(v_id,v_player,auth.uid(),'YES');
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 if v_players=1 then
   update public.debate_pause_proposals set status='accepted' where id=v_id;
   update public.rounds set paused=p_desired_paused where id=p_round_id;
 end if;
 return jsonb_build_object('id',v_id,'yes',1,'players',v_players);
end $function$
;

CREATE OR REPLACE FUNCTION public.propose_debate_revote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_num bigint; v_status text; v_id bigint; v_player text; v_players bigint;
begin
 perform private.context_guard(p_round_id);
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 if exists(select 1 from public.debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open')
 then raise exception 'Another proposal must be resolved first'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select proposal_number,status into v_num,v_status from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle order by proposal_number desc limit 1;
 if v_status='accepted' then raise exception 'Revote already accepted'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Revote already open'; end if;
 if v_status='open' then return v_num; end if;
 v_num:=coalesce(v_num,0)+1;
 insert into public.debate_revote_proposals(round_id,vote_cycle,proposal_number) values(p_round_id,v_cycle,v_num) returning id into v_id;
 insert into public.debate_revote_votes(proposal_id,player_id,user_id,choice) values(v_id,v_player,(select auth.uid()),'YES');
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 if v_players=1 then
   update public.debate_revote_proposals set status='accepted' where id=v_id;
   insert into public.debate_optional_revote_windows(round_id,vote_cycle,opened_by) values(p_round_id,v_cycle,(select auth.uid())) on conflict do nothing;
 end if;
 return v_num;
end $function$
;

CREATE OR REPLACE FUNCTION public.propose_debate_twist_vote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_open boolean;v_paused boolean;v_num bigint;v_player text;v_players bigint;
begin
 perform private.context_guard(p_round_id);
 select room_id,vote_cycle,debate_phase,twist_request_open,paused into v_room,v_cycle,v_phase,v_open,v_paused from rounds where id=p_round_id for update;
 if v_phase<>'debate' or not coalesce(v_open,false) or v_paused then raise exception 'GIRO not available'; end if;
 if exists(select 1 from debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open')
 or exists(select 1 from debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Another proposal must be resolved first'; end if;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select proposal_number into v_num from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open' order by proposal_number desc limit 1;
 if v_num is null then
   select coalesce(max(proposal_number),0)+1 into v_num from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle;
   insert into debate_twist_proposals(id,round_id,vote_cycle,proposal_number,proposed_by) values((extract(epoch from clock_timestamp())*1000000)::bigint,p_round_id,v_cycle,v_num,auth.uid());
   insert into debate_twist_votes(id,round_id,vote_cycle,proposal_number,player_id,user_id,choice)
   values((extract(epoch from clock_timestamp())*1000000)::bigint,p_round_id,v_cycle,v_num,v_player,auth.uid(),'YES');
   select count(*) into v_players from players where room_id=v_room and abandoned_at is null and presence='present';
   if v_players=1 then
     update debate_twist_proposals set status='accepted' where round_id=p_round_id and vote_cycle=v_cycle and proposal_number=v_num;
     perform launch_debate_twist(p_round_id,'requested');
   end if;
 end if;
 return v_num;
end $function$
;

CREATE OR REPLACE FUNCTION public.propose_presence_change(p_round_id bigint, p_action text, p_message text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_me text;v_presence text;v_id bigint;
begin
 perform private.context_guard(p_round_id);
 if p_action<>'return' then raise exception 'Only return requires table approval'; end if;
 select room_id into v_room from rounds where id=p_round_id;
 select player_id,presence into v_me,v_presence from players where room_id=v_room and user_id=auth.uid() limit 1;
 if v_me is null or v_presence<>'absent' then raise exception 'Not absent'; end if;
 if exists(select 1 from debate_presence_requests where round_id=p_round_id and player_id=v_me and status='open') then raise exception 'Request already open'; end if;
 v_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
 insert into debate_presence_requests(id,round_id,player_id,user_id,action,message) values(v_id,p_round_id,v_me,auth.uid(),'return',null);
 return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.cast_debate_secret_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_player text; v_resource bigint; v_old text;
begin
 perform private.context_guard(p_round_id);
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Secret revote unavailable'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Public revote in progress'; end if;
 select player_id into v_player from public.players
 where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_resource from public.debate_secret_revotes
 where round_id=p_round_id and player_id=v_player and user_id=(select auth.uid()) and used_at is null for update;
 if v_resource is null then raise exception 'No secret revote available'; end if;
 select choice into v_old from public.debate_vote_cycles
 where round_id=p_round_id and cycle_number=v_cycle and player_id=v_player for update;
 if v_old is null then raise exception 'Vote missing'; end if;
 if v_old=p_choice then raise exception 'Choose a different option'; end if;
 update public.debate_vote_cycles set choice=p_choice where round_id=p_round_id and cycle_number=v_cycle and player_id=v_player;
 update public.debate_secret_revotes set used_at=now(),used_cycle=v_cycle,from_choice=v_old,to_choice=p_choice where id=v_resource;
end $function$
;

CREATE OR REPLACE FUNCTION public.cast_debate_unanimity_choice(p_round_id bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_player text;v_players bigint;va bigint;vb bigint;v_id bigint;v_outcome text;v_continue bigint;v_giro bigint;v_finish bigint;v_need bigint;
begin
 perform private.context_guard(p_round_id);
 if p_choice not in ('CONTINUE','GIRO','FINISH') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' then raise exception 'No active debate'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where d.choice='A'),count(*) filter(where d.choice='B') into va,vb
 from public.debate_vote_cycles d join public.players p on p.room_id=v_room and p.player_id=d.player_id
 where d.round_id=p_round_id and d.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 if v_players<2 or not ((va=v_players and vb=0) or (vb=v_players and va=0)) then raise exception 'The vote is not unanimous'; end if;
 insert into public.debate_unanimity_decisions(round_id,vote_cycle) values(p_round_id,v_cycle)
 on conflict(round_id,vote_cycle) do nothing;
 select id,outcome into v_id,v_outcome from public.debate_unanimity_decisions where round_id=p_round_id and vote_cycle=v_cycle;
 if v_outcome is not null then raise exception 'Already decided'; end if;
 insert into public.debate_unanimity_votes(decision_id,player_id,user_id,choice)
 values(v_id,v_player,(select auth.uid()),p_choice)
 on conflict(decision_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) filter(where v.choice='CONTINUE'),count(*) filter(where v.choice='GIRO'),count(*) filter(where v.choice='FINISH')
 into v_continue,v_giro,v_finish from public.debate_unanimity_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.decision_id=v_id and p.abandoned_at is null and p.presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 if v_continue>=v_need then v_outcome:='CONTINUE';
 elsif v_giro>=v_need then
   perform public.launch_debate_twist(p_round_id,'unanimity');
   v_outcome:='GIRO';
 elsif v_finish=v_players then
   update public.rounds set debate_phase='finished',status='finished',twist_request_open=false where id=p_round_id;
   v_outcome:='FINISH';
 elsif v_continue+v_giro+v_finish=v_players then
   v_outcome:='CONTINUE';
 end if;
 if v_outcome is not null then update public.debate_unanimity_decisions set outcome=v_outcome where id=v_id; end if;
 return jsonb_build_object('outcome',v_outcome,'voted',v_continue+v_giro+v_finish,'players',v_players);
end $function$
;

CREATE OR REPLACE FUNCTION public.request_debate_twist(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_cycle bigint; v_player text; vp bigint; vr bigint; v_twist bigint;
begin
 perform private.context_guard(p_round_id);
 select room_id,vote_cycle into v_room,v_cycle from rounds where id=p_round_id;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active in room'; end if;
 insert into debate_twist_requests(round_id,vote_cycle,player_id,user_id)
 values(p_round_id,v_cycle,v_player,auth.uid())
 on conflict(round_id,vote_cycle,player_id) do nothing;
 select count(*) into vp from players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into vr from debate_twist_requests d join players p on p.player_id=d.player_id and p.room_id=v_room
 where d.round_id=p_round_id and d.vote_cycle=v_cycle and p.abandoned_at is null and p.presence='present';
 if vr>vp/2 and not exists(select 1 from debate_twists where round_id=p_round_id and vote_cycle=v_cycle) then
   v_twist:=public.launch_debate_twist(p_round_id,'requested');
 end if;
 return jsonb_build_object('requests',vr,'players',vp,'launched',v_twist is not null,'twist_id',v_twist);
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_propose_dilemma(p_room bigint, p_dilemma bigint DEFAULT NULL::bigint, p_question text DEFAULT NULL::text, p_a text DEFAULT NULL::text, p_b text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.rooms; d public.dilemmas; new_id bigint;
begin
 select * into r from rooms where id=p_room for update;
 if r.id is null or r.mode <> 'debate' or r.status <> 'waiting' or auth.uid() is null or not exists(select 1 from players where room_id=p_room and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Solo el anfitrión puede proponer'; end if;
 if exists(select 1 from debate_dilemma_proposals where room_id=p_room and status in ('open','accepted')) then raise exception 'Ya hay un dilema propuesto'; end if;
 if p_dilemma is not null then
  select * into d from dilemmas where id=p_dilemma and active=true and audience='teen';
  if d.id is null then raise exception 'Dilema no disponible'; end if;
  if exists(select 1 from debate_dilemma_proposals where room_id=p_room and dilemma_id=p_dilemma and status='rejected') then raise exception 'Este dilema ya fue descartado'; end if;
  p_question:=d.question;p_a:=d.option_a;p_b:=d.option_b;
 else
  if length(trim(coalesce(p_question,''))) not between 1 and 1000 or length(trim(coalesce(p_a,''))) not between 1 and 500 or length(trim(coalesce(p_b,''))) not between 1 and 500 then raise exception 'Completa la pregunta y ambas opciones'; end if;
 end if;
 insert into debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by)
 values(p_room,p_dilemma,trim(p_question),trim(p_a),trim(p_b),coalesce(d.category,'PERSONALIZADO'),auth.uid()) returning id into new_id;
 insert into debate_dilemma_proposal_votes(proposal_id,user_id,choice) values(new_id,auth.uid(),true);
 perform debate_recount_proposal(new_id);
 return new_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_start_approved(p_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.debate_dilemma_proposals; r public.rooms; dilemma bigint; round_id bigint;
begin
 select * into p from debate_dilemma_proposals where id=p_id;
 select * into r from rooms where id=p.room_id for update;
 if p.id is null or p.status <> 'accepted' or r.status <> 'waiting' or r.mode <> 'debate' or auth.uid() is null or not exists(select 1 from players where room_id=r.id and user_id=auth.uid() and player_id=r.host_id and abandoned_at is null and presence='present') then raise exception 'Dilema sin aprobar o anfitrión no autorizado'; end if;
 dilemma:=p.dilemma_id;
 if dilemma is null then
  insert into dilemmas(audience,category,intensity,question,option_a,option_b,active)
  values('custom','PERSONALIZADO',1,p.question,p.option_a,p.option_b,true) returning id into dilemma;
 end if;
 insert into rounds(room_id,round_number,dilemma_id,status,started_at,context)
 values(r.id,coalesce((select max(round_number) from rounds where room_id=r.id),0)+1,dilemma,'voting',now(),p.context) returning id into round_id;
 update rooms set status='playing' where id=r.id;
 update debate_dilemma_proposals set status='launched' where id=p_id;
 return round_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.prepare_debate_assistant(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_dilemma bigint;v_phase text;v_cycle bigint;v_paused boolean;v_choice text;
 v_question text;v_a text;v_b text;v_twist text;v_source text;v_guide public.debate_assistant_guides%rowtype;
 v_approved boolean;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select room_id,dilemma_id,debate_phase,vote_cycle,paused into v_room,v_dilemma,v_phase,v_cycle,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Assistant unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Wait for revote'; end if;
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() limit 1;
 if v_choice not in ('A','B') then raise exception 'Vote before opening the assistant'; end if;
 select question,option_a,option_b into v_question,v_a,v_b from public.dilemmas where id=v_dilemma;
 if v_question is null then raise exception 'Dilemma unavailable'; end if;
 select text into v_twist from public.debate_twists where round_id=p_round_id order by id desc limit 1;
 update public.debate_assistant_tokens set used_at=now()
 where id=(select id from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null order by granted_at,id limit 1)
 returning 'token' into v_source;
 if v_source is null then
  select exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) into v_approved;
  if v_approved then
   update public.debate_assistant_requests set used_at=now()
   where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice and used_at is null
   returning 'group' into v_source;
  end if;
 end if;
 if v_source is null then
  select * into v_guide from public.debate_assistant_guides
  where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice
  order by id desc limit 1;
  if v_guide.id is null then raise exception 'Guide not available'; end if;
  v_source:=v_guide.source;
 else
  insert into public.debate_assistant_guides(round_id,user_id,cycle_number,choice,source)
  values(p_round_id,auth.uid(),v_cycle,v_choice,v_source)
  on conflict(round_id,user_id,cycle_number,choice,source) do nothing;
  select * into v_guide from public.debate_assistant_guides
  where round_id=p_round_id and user_id=auth.uid() and cycle_number=v_cycle and choice=v_choice and source=v_source;
 end if;
 return jsonb_build_object('status',case when v_guide.status='ready' then 'ready' else 'draft' end,
  'guide',v_guide.guide,'mode',v_guide.mode,'source',v_source,'question',v_question,'option_a',v_a,'option_b',v_b,
  'choice',v_choice,'twist',v_twist,'cycle',v_cycle,'context',(select context from public.rounds where id=p_round_id));
end $function$
;

CREATE OR REPLACE FUNCTION public.debate_proposal_state(p_room bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.debate_dilemma_proposals; r public.rooms; yes_count integer; no_count integer; total integer; mine boolean;
begin
 select * into r from rooms where id=p_room;
 if r.id is null or auth.uid() is null or not exists(select 1 from players where room_id=p_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'No perteneces a esta mesa'; end if;
 if r.mode <> 'debate' or r.status <> 'waiting' then return '{}'::jsonb; end if;
 select * into p from debate_dilemma_proposals where room_id=p_room and status in ('open','accepted') order by id desc limit 1;
 if p.id is null then return jsonb_build_object('rejected_ids',coalesce((select jsonb_agg(dilemma_id) from debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null),'[]'::jsonb)); end if;
 select count(*) filter(where choice),count(*) filter(where not choice) into yes_count,no_count from debate_dilemma_proposal_votes where proposal_id=p.id;
 select count(*) into total from players where room_id=p_room and abandoned_at is null and presence='present';
 select choice into mine from debate_dilemma_proposal_votes where proposal_id=p.id and user_id=auth.uid();
 return jsonb_build_object('id',p.id,'status',p.status,'dilemma_id',p.dilemma_id,'question',p.question,'option_a',p.option_a,'option_b',p.option_b,'category',p.category,'context',p.context,'yes',yes_count,'no',no_count,'total',total,'my_vote',mine,'has_voted',exists(select 1 from debate_dilemma_proposal_votes where proposal_id=p.id and user_id=auth.uid()),'rejected_ids',coalesce((select jsonb_agg(dilemma_id) from debate_dilemma_proposals where room_id=p_room and status='rejected' and dilemma_id is not null),'[]'::jsonb));
end $function$

;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
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
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id));
end $function$

;
