alter table public.debate_twist_proposals add column if not exists proposed_by uuid;
alter table public.rounds add column if not exists close_proposed_by uuid;

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
end $function$;

CREATE OR REPLACE FUNCTION public.get_debate_twist_proposal(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;v_num bigint;v_status text;v_yes bigint;v_no bigint;v_mine text;v_players bigint;v_proposer uuid;
begin
 select room_id,vote_cycle into v_room,v_cycle from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select proposal_number,status,proposed_by into v_num,v_status,v_proposer from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle order by proposal_number desc limit 1;
 if v_num is null then return null; end if;
 select count(*) into v_players from players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where tv.choice='YES'),count(*) filter(where tv.choice='NO') into v_yes,v_no from debate_twist_votes tv join players p on p.player_id=tv.player_id and p.room_id=v_room where tv.round_id=p_round_id and tv.vote_cycle=v_cycle and tv.proposal_number=v_num and p.abandoned_at is null and p.presence='present';
 select choice into v_mine from debate_twist_votes where round_id=p_round_id and vote_cycle=v_cycle and proposal_number=v_num and user_id=auth.uid() limit 1;
 return jsonb_build_object('proposal',v_num,'status',v_status,'yes',coalesce(v_yes,0),'no',coalesce(v_no,0),'voted',coalesce(v_yes,0)+coalesce(v_no,0),'players',v_players,'mine',v_mine,'proposer_me',v_proposer=auth.uid());
end $function$;

CREATE OR REPLACE FUNCTION public.cast_debate_twist_vote(p_round_id bigint, p_choice text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;v_num bigint;v_phase text;v_paused boolean;v_player text;v_players bigint;v_yes bigint;v_no bigint;v_need bigint;
begin
 if p_choice not in('YES','NO') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from rounds where id=p_round_id;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'GIRO vote unavailable'; end if;
 select proposal_number into v_num from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open' order by proposal_number desc limit 1;
 if v_num is null then raise exception 'No GIRO proposal'; end if;
 if exists(select 1 from debate_twist_proposals where round_id=p_round_id and vote_cycle=v_cycle and proposal_number=v_num and proposed_by=auth.uid()) then raise exception 'Proposer has already voted YES'; end if;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into debate_twist_votes(id,round_id,vote_cycle,proposal_number,player_id,user_id,choice)
 values((extract(epoch from clock_timestamp())*1000000)::bigint,p_round_id,v_cycle,v_num,v_player,auth.uid(),p_choice)
 on conflict(round_id,vote_cycle,proposal_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from players where room_id=v_room and abandoned_at is null and presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no
 from debate_twist_votes tv join players p on p.player_id=tv.player_id and p.room_id=v_room
 where tv.round_id=p_round_id and tv.vote_cycle=v_cycle and tv.proposal_number=v_num and p.abandoned_at is null and p.presence='present';
 if v_yes>=v_need then
   update debate_twist_proposals set status='accepted' where round_id=p_round_id and vote_cycle=v_cycle and proposal_number=v_num;
   perform launch_debate_twist(p_round_id,'requested');
   return true;
 elsif v_no>=v_need then
   update debate_twist_proposals set status='rejected' where round_id=p_round_id and vote_cycle=v_cycle and proposal_number=v_num;
   return false;
 end if;
 return false;
end $function$;

CREATE OR REPLACE FUNCTION public.propose_debate_close(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_num bigint; v_player text; v_players bigint; v_phase text;
begin
 select room_id,close_proposal_number+1,debate_phase into v_room,v_num,v_phase from rounds where id=p_round_id for update;
 if v_phase<>'debate' then raise exception 'Close proposal unavailable'; end if;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 update rounds set close_proposal_number=v_num,debate_phase='closing',close_proposed_by=auth.uid() where id=p_round_id;
 insert into debate_close_votes(round_id,proposal_number,player_id,user_id,choice) values(p_round_id,v_num,v_player,auth.uid(),'YES');
 select count(*) into v_players from players where room_id=v_room and abandoned_at is null and presence='present';
 if v_players=1 then update rounds set debate_phase='finished',status='finished',twist_request_open=false where id=p_round_id; end if;
 return v_num;
end $function$;

CREATE OR REPLACE FUNCTION public.cast_debate_close_vote(p_round_id bigint, p_choice text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_num bigint;v_player text;vp bigint;vy bigint;vn bigint;
begin
 if p_choice not in('YES','NO') then raise exception 'Invalid choice'; end if;
 select room_id,close_proposal_number into v_room,v_num from rounds where id=p_round_id;
 if exists(select 1 from rounds where id=p_round_id and close_proposed_by=auth.uid() and debate_phase='closing') then raise exception 'Proposer has already voted YES'; end if;
 select player_id into v_player from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_player is null or v_num=0 then raise exception 'No close proposal'; end if;
 insert into debate_close_votes(round_id,proposal_number,player_id,user_id,choice)
 values(p_round_id,v_num,v_player,auth.uid(),p_choice)
 on conflict(round_id,proposal_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into vp from players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where d.choice='YES'),count(*) filter(where d.choice='NO') into vy,vn
 from debate_close_votes d join players p on p.room_id=v_room and p.player_id=d.player_id
 where d.round_id=p_round_id and d.proposal_number=v_num and p.abandoned_at is null and p.presence='present';
 if vn>0 then
   update rounds set debate_phase='debate',twist_request_open=true where id=p_round_id;
   return false;
 end if;
 if vy=vp and vp>0 then
   update rounds set debate_phase='finished',status='finished',twist_request_open=false where id=p_round_id;
   return true;
 end if;
 return false;
end $function$;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_close_proposer uuid;
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
 if v_close>0 then
   select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no
   from debate_close_votes dcv join players p on p.player_id=dcv.player_id and p.room_id=v_room
   where dcv.round_id=p_round_id and dcv.proposal_number=v_close and p.abandoned_at is null and p.presence='present';
 end if;
 return jsonb_build_object('phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used);
end $function$;