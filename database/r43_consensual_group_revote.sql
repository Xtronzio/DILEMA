-- R43: la apertura del re-voto general necesita mayoría; la propuesta cuenta como SÍ del solicitante.
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

CREATE OR REPLACE FUNCTION public.cast_debate_revote_proposal_vote(p_round_id bigint, p_choice text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_player text; v_id bigint; v_players bigint; v_yes bigint; v_no bigint; v_need bigint; v_paused boolean;
begin
 if p_choice not in ('YES','NO') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'No active debate'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 select id into v_id from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='open' order by proposal_number desc limit 1;
 if v_id is null then raise exception 'No open revote proposal'; end if;
 if exists(select 1 from public.debate_revote_votes where proposal_id=v_id and player_id=v_player) then raise exception 'Vote already registered'; end if;
 insert into public.debate_revote_votes(proposal_id,player_id,user_id,choice) values(v_id,v_player,(select auth.uid()),p_choice)
 on conflict(proposal_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 v_need:=floor(v_players/2.0)::bigint+1;
 select count(*) filter(where v.choice='YES'),count(*) filter(where v.choice='NO') into v_yes,v_no
 from public.debate_revote_votes v join public.players p on p.room_id=v_room and p.player_id=v.player_id
 where v.proposal_id=v_id and p.abandoned_at is null and p.presence='present';
 if v_yes>=v_need then
   update public.debate_revote_proposals set status='accepted' where id=v_id;
   insert into public.debate_optional_revote_windows(round_id,vote_cycle,opened_by)
   values(p_round_id,v_cycle,(select auth.uid())) on conflict do nothing;
   return true;
 elsif v_no>=v_need or v_yes+v_no>=v_players then
   update public.debate_revote_proposals set status='rejected' where id=v_id;
 end if;
 return false;
end $function$
;

CREATE OR REPLACE FUNCTION public.open_optional_debate_revote(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if not exists(select 1 from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='accepted') then raise exception 'The table must approve the revote'; end if;
 insert into public.debate_optional_revote_windows(round_id,vote_cycle,opened_by)
 values(p_round_id,v_cycle,(select auth.uid())) on conflict do nothing;
end $function$
;
