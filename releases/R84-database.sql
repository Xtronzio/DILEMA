CREATE OR REPLACE FUNCTION private.limbo_state(p_round bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_phase text;v_paused boolean;l private.debate_limbo_proposals%rowtype;m private.debate_limbo_proposals%rowtype;v_yes bigint;v_no bigint;v_players bigint;v_mine text;v_targets jsonb;v_me text;v_presence text;
begin
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round;
 select player_id,presence into v_me,v_presence from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if auth.uid() is null or v_me is null then raise exception 'Not in room';end if;
 select * into l from private.debate_limbo_proposals where round_id=p_round and status='open' limit 1;
 if l.id is not null then perform private.resolve_limbo(l.id);select * into l from private.debate_limbo_proposals where id=l.id;end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select coalesce(jsonb_agg(jsonb_build_object('id',player_id,'name',name) order by created_at,player_id),'[]'::jsonb) into v_targets
 from public.players where room_id=v_room and abandoned_at is null and presence='present' and user_id<>auth.uid();
 select * into m from private.debate_limbo_proposals where round_id=p_round and target_user_id=auth.uid() and status='accepted' order by id desc limit 1;
 if l.status='open' then
  select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no from private.debate_limbo_votes v where proposal_id=l.id and v.user_id<>l.target_user_id and exists(select 1 from public.players p where p.room_id=v_room and p.user_id=v.user_id and p.presence='present' and p.abandoned_at is null);
  select choice into v_mine from private.debate_limbo_votes where proposal_id=l.id and user_id=auth.uid();
 end if;
 select presence into v_presence from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 return jsonb_build_object('server_now',clock_timestamp(),'phase',v_phase,'paused',v_paused,'present',v_presence='present','targets',v_targets,'can_propose',v_players>=3,

 'blocked',private.limbo_blocked(v_room,auth.uid()),'until_at',m.until_at,'until_end',m.id is not null and m.duration_seconds=0,
 'proposal',case when l.status='open' then jsonb_build_object('id',l.id,'name',l.target_name,'duration',l.duration_seconds,'proposer_me',l.proposer_user_id=auth.uid(),'target_me',l.target_user_id=auth.uid(),'can_vote',v_presence='present' and auth.uid()<>l.target_user_id and auth.uid()<>l.proposer_user_id,'yes',v_yes,'no',v_no,'players',v_players-1,'mine',v_mine) else null end);
end $function$;

CREATE OR REPLACE FUNCTION private.resolve_limbo(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare l private.debate_limbo_proposals%rowtype;v_room bigint;v_phase text;v_players bigint;v_yes bigint;v_no bigint;v_need bigint;v_host text;v_next text;
begin
 select * into l from private.debate_limbo_proposals where id=p_id;
 if l.id is null or l.status<>'open' then return;end if;
 select room_id,debate_phase into v_room,v_phase from public.rounds where id=l.round_id for update;
 select * into l from private.debate_limbo_proposals where id=p_id for update;
 if l.status<>'open' then return;end if;
 if v_phase<>'debate' or not exists(select 1 from public.players where room_id=v_room and user_id=l.target_user_id and abandoned_at is null and presence='present') then
  update private.debate_limbo_proposals set status='rejected' where id=p_id;return;
 end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present' and user_id<>l.target_user_id;
 if v_players<2 then update private.debate_limbo_proposals set status='rejected' where id=p_id;return;end if;
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from private.debate_limbo_votes v where v.proposal_id=p_id and v.user_id<>l.target_user_id and exists(select 1 from public.players p where p.room_id=v_room and p.user_id=v.user_id and p.abandoned_at is null and p.presence='present');
 v_need:=floor(v_players/2.0)::bigint+1;
 if v_yes>=v_need then
  select host_id into v_host from public.rooms where id=v_room for update;
  if v_host=l.target_player_id then
   select player_id into v_next from public.players where room_id=v_room and abandoned_at is null and presence='present' and user_id<>l.target_user_id order by created_at,player_id limit 1;
   if v_next is null then update private.debate_limbo_proposals set status='rejected' where id=p_id;return;end if;
   update public.rooms set host_id=v_next where id=v_room;
  end if;
  update private.debate_limbo_proposals set status='accepted',accepted_at=clock_timestamp(),until_at=case when duration_seconds=0 then null else clock_timestamp()+make_interval(secs=>duration_seconds) end where id=p_id;
  update public.players set presence='absent' where room_id=v_room and user_id=l.target_user_id;
  update public.debate_presence_requests set status='rejected' where round_id=l.round_id and player_id=l.target_player_id and status='open';
 elsif v_no>v_players-v_need or v_yes+v_no>=v_players then
  update private.debate_limbo_proposals set status='rejected' where id=p_id;
 end if;
end $function$;

CREATE OR REPLACE FUNCTION private.limbo_action(p_round bigint, p_target text, p_duration integer, p_proposal bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_phase text;v_paused boolean;v_cycle bigint;v_me text;v_target public.players%rowtype;v_id bigint;l private.debate_limbo_proposals%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select room_id,debate_phase,paused,vote_cycle into v_room,v_phase,v_paused,v_cycle from public.rounds where id=p_round for update;
 select player_id into v_me from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Not active';end if;
 if p_proposal is not null then
  select * into l from private.debate_limbo_proposals where id=p_proposal and round_id=p_round for update;
  if l.id is null or l.status<>'open' or v_phase<>'debate' then return jsonb_build_object('status','closed');end if;
  if l.target_user_id=auth.uid() then raise exception 'Target cannot vote own limbo';end if;
  perform private.resolve_limbo(l.id);
  if (select status from private.debate_limbo_proposals where id=l.id)<>'open' then return jsonb_build_object('status','closed');end if;
  if p_choice is null or p_choice not in('YES','NO') then raise exception 'Invalid choice';end if;
  if l.proposer_user_id=auth.uid() then raise exception 'Proposer already voted YES';end if;
  insert into private.debate_limbo_votes values(l.id,auth.uid(),p_choice) on conflict(proposal_id,user_id) do update set choice=excluded.choice;
  perform private.resolve_limbo(l.id);
  return jsonb_build_object('status',(select status from private.debate_limbo_proposals where id=l.id));
 end if;
 perform private.context_guard(p_round);
 if v_phase<>'debate' or v_paused or p_duration is null or p_duration not in(0,180,300,600) then raise exception 'Limbo unavailable';end if;
 if exists(select 1 from public.debate_pause_proposals where round_id=p_round and status='open')
 or exists(select 1 from public.debate_presence_requests where round_id=p_round and status='open')
 or exists(select 1 from public.debate_twist_proposals where round_id=p_round and vote_cycle=v_cycle and status='open')
 or exists(select 1 from public.debate_revote_proposals where round_id=p_round and vote_cycle=v_cycle and status='open')
 or exists(select 1 from public.debate_optional_revote_windows where round_id=p_round and vote_cycle=v_cycle and closed_at is null)
 then raise exception 'Another proposal must be resolved first';end if;
 if (select count(*) from public.players where room_id=v_room and abandoned_at is null and presence='present')<3 then raise exception 'Limbo requires at least three present players';end if;
 select * into v_target from public.players where room_id=v_room and player_id=p_target and abandoned_at is null and presence='present' and user_id<>auth.uid() limit 1;
 if v_target.id is null then raise exception 'Target unavailable';end if;
 insert into private.debate_limbo_proposals(round_id,target_user_id,target_player_id,target_name,proposer_user_id,duration_seconds)
 values(p_round,v_target.user_id,v_target.player_id,v_target.name,auth.uid(),p_duration) returning id into v_id;
 insert into private.debate_limbo_votes values(v_id,auth.uid(),'YES');
 return jsonb_build_object('id',v_id,'status','open');
end $function$;
