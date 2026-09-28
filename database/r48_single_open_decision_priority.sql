CREATE OR REPLACE FUNCTION public.propose_debate_close(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_num bigint; v_player text; v_players bigint; v_phase text;v_cycle bigint;
begin
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

CREATE OR REPLACE FUNCTION public.propose_debate_twist_vote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_open boolean;v_paused boolean;v_num bigint;v_player text;v_players bigint;
begin
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

CREATE OR REPLACE FUNCTION public.propose_debate_revote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_num bigint; v_status text; v_id bigint; v_player text; v_players bigint;
begin
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
