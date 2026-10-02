-- R90: neutral posture. Existing A/B data and active rounds are preserved.

ALTER TABLE public.debate_vote_cycles DROP CONSTRAINT debate_vote_cycles_choice_check;
ALTER TABLE public.debate_vote_cycles ADD CONSTRAINT debate_vote_cycles_choice_check CHECK (choice IN ('A','B','N'));

ALTER TABLE public.debate_optional_revote_choices DROP CONSTRAINT debate_optional_revote_choices_choice_check;
ALTER TABLE public.debate_optional_revote_choices ADD CONSTRAINT debate_optional_revote_choices_choice_check CHECK (choice IN ('A','B','N'));

ALTER TABLE public.debate_secret_revotes DROP CONSTRAINT debate_secret_revotes_from_choice_check;
ALTER TABLE public.debate_secret_revotes ADD CONSTRAINT debate_secret_revotes_from_choice_check CHECK (from_choice IN ('A','B','N'));

ALTER TABLE public.debate_secret_revotes DROP CONSTRAINT debate_secret_revotes_to_choice_check;
ALTER TABLE public.debate_secret_revotes ADD CONSTRAINT debate_secret_revotes_to_choice_check CHECK (to_choice IN ('A','B','N'));

ALTER TABLE public.saved_group_dilemmas DROP CONSTRAINT saved_group_dilemmas_choice_check;
ALTER TABLE public.saved_group_dilemmas ADD CONSTRAINT saved_group_dilemmas_choice_check CHECK (choice IN ('A','B','N'));

ALTER TABLE public.private_dilemma_sessions DROP CONSTRAINT private_dilemma_sessions_choice_check;
ALTER TABLE public.private_dilemma_sessions ADD CONSTRAINT private_dilemma_sessions_choice_check CHECK (choice IN ('A','B','N'));

CREATE OR REPLACE FUNCTION private.require_position(p_round bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(
 SELECT 1 FROM public.rounds r JOIN public.players p ON p.room_id=r.room_id
 JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
 WHERE r.id=p_round AND p.user_id=auth.uid() AND p.abandoned_at IS NULL AND p.presence='present' AND v.choice IN ('A','B'))
 THEN RAISE EXCEPTION 'Choose A or B to use tools'; END IF;
END $fn$;

REVOKE ALL ON FUNCTION private.require_position(bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cast_debate_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_player text;
begin
 if p_choice is null or p_choice not in ('A','B','N') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if exists(select 1 from public.rounds where id=p_round_id and paused) or v_room is null or v_phase<>'twist' then raise exception 'Revote unavailable'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 if not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle)
 and not exists(select 1 from public.debate_revote_proposals where round_id=p_round_id and vote_cycle=v_cycle and status='accepted')
 then raise exception 'No approved revote'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle+1,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
end $function$;

CREATE OR REPLACE FUNCTION public.cast_optional_debate_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean;
 v_player text; v_window bigint; v_players bigint; v_voted bigint;
begin
 if p_choice is null or p_choice not in ('A','B','N') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused
 from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 select id into v_window from public.debate_optional_revote_windows
 where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null;
 if v_window is null then raise exception 'Revote window closed'; end if;
 select player_id into v_player from public.players
 where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into public.debate_optional_revote_choices(window_id,player_id,user_id,choice)
 values(v_window,v_player,(select auth.uid()),p_choice) on conflict(window_id,player_id) do nothing;
 if not found then raise exception 'Already revoted this cycle'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players
 where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into v_voted from public.debate_optional_revote_choices c
 join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window and p.abandoned_at is null and p.presence='present';
 if v_players>0 and v_voted>=v_players then
  update public.debate_optional_revote_windows set closed_at=now() where id=v_window;
  insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
  select p_round_id,v_cycle+1,p.player_id,p.user_id,c.choice
  from public.players p join public.debate_optional_revote_choices c
   on c.window_id=v_window and c.player_id=p.player_id
  where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
  on conflict(round_id,cycle_number,player_id) do update
   set choice=excluded.choice,user_id=excluded.user_id;
  update public.rounds set vote_cycle=v_cycle+1,twist_request_open=true where id=p_round_id;
  perform public.draw_debate_proclamation(p_round_id);
  perform public.draw_debate_secret_revote(p_round_id);
 end if;
end $function$;

CREATE OR REPLACE FUNCTION public.cast_debate_secret_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_player text; v_resource bigint; v_old text;
begin
 perform private.context_guard(p_round_id);
 perform private.require_position(p_round_id);
 if p_choice is null or p_choice not in ('A','B','N') then raise exception 'Invalid choice'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION private.admission_initial_vote(p_round bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rounds;pid text;
begin
 select * into r from public.rounds where id=p_round for update;
 if p_choice is null or p_choice not in('A','B','N') or r.status<>'debate' or private.admission_busy(p_round) or exists(select 1 from private.debate_admissions where round_id=p_round and status='open') then raise exception 'Vote unavailable';end if;
 select player_id into pid from public.players where room_id=r.room_id and user_id=auth.uid() and presence='present' and abandoned_at is null;
 if pid is null or not exists(select 1 from private.debate_admissions where round_id=p_round and user_id=auth.uid() and status='accepted') then raise exception 'Not admitted';end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) values(p_round,r.vote_cycle,pid,auth.uid(),p_choice) on conflict(round_id,cycle_number,player_id) do nothing;
end $function$;

CREATE OR REPLACE FUNCTION public.draw_debate_proclamation(p_round_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_player text;v_user uuid;v_name text;
begin
 select room_id into v_room from public.rounds where id=p_round_id;
 if v_room is null then raise exception 'Round not found'; end if;
 select p.player_id,p.user_id,p.name into v_player,v_user,v_name
 from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null and exists(select 1 from public.debate_vote_cycles v join public.rounds r on r.id=v.round_id where v.round_id=p_round_id and v.cycle_number=r.vote_cycle and v.user_id=p.user_id and v.choice in ('A','B'))
 and not exists(select 1 from public.debate_proclamations d where d.round_id=p_round_id and d.player_id=p.player_id and d.used_at is null)
 order by random() limit 1;
 if v_player is null then return null; end if;
 insert into public.debate_proclamations(round_id,player_id,user_id,proclamation_id)
 values(p_round_id,v_player,v_user,null);
 return coalesce(v_name,'JUGADOR');
end $function$;

CREATE OR REPLACE FUNCTION public.draw_debate_secret_revote(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_player text; v_user uuid;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null then raise exception 'Round not found'; end if;
 select p.player_id,p.user_id into v_player,v_user
 from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null and exists(select 1 from public.debate_vote_cycles v join public.rounds r on r.id=v.round_id where v.round_id=p_round_id and v.cycle_number=r.vote_cycle and v.user_id=p.user_id and v.choice in ('A','B'))
   and not exists (select 1 from public.debate_secret_revotes s where s.round_id=p_round_id and s.player_id=p.player_id and s.used_at is null)
 order by random() limit 1;
 if v_player is null then return; end if;
 insert into public.debate_secret_revotes(round_id,player_id,user_id,grant_cycle)
 values (p_round_id,v_player,v_user,v_cycle);
end $function$;

CREATE OR REPLACE FUNCTION public.draw_debate_assistant(p_round_id bigint, p_grant_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_user uuid;
begin
 select room_id into v_room from public.rounds where id=p_round_id;
 if v_room is null then return; end if;
 select p.user_id into v_user from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null and exists(select 1 from public.debate_vote_cycles v join public.rounds r on r.id=v.round_id where v.round_id=p_round_id and v.cycle_number=r.vote_cycle and v.user_id=p.user_id and v.choice in ('A','B'))
 and not exists(select 1 from public.debate_assistant_tokens t where t.round_id=p_round_id and t.user_id=p.user_id and t.used_at is null)
 order by random() limit 1;
 if v_user is not null then
  insert into public.debate_assistant_tokens(round_id,user_id,grant_key)
  values(p_round_id,v_user,p_grant_key) on conflict(round_id,grant_key) do nothing;
 end if;
end $function$;

CREATE OR REPLACE FUNCTION public.init_debate_engine(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_count bigint; v_needed bigint;
begin
  select room_id into v_room from rounds where id=p_round_id for update;
  if v_room is null then raise exception 'Round not found'; end if;
  if not exists(select 1 from players where room_id=v_room and user_id=auth.uid()) then raise exception 'Not in room'; end if;

  insert into debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
  select p_round_id,1,p.player_id,p.user_id,v.choice
  from votes v join players p on p.player_id=v.player_id and p.room_id=v_room
  where v.round_id=p_round_id
  on conflict(round_id,cycle_number,player_id) do nothing;

  update rounds set debate_phase='debate',vote_cycle=1,twist_request_open=true
  where id=p_round_id and debate_phase='initial_vote';

  if not exists(select 1 from debate_proclamations where round_id=p_round_id) then
    select count(*) into v_count from players where room_id=v_room and abandoned_at is null and presence='present';
    v_needed:=floor(v_count/2.0);
    insert into debate_proclamations(round_id,player_id,user_id)
    select p_round_id,pp.player_id,pp.user_id
    from players pp where pp.room_id=v_room and pp.abandoned_at is null and pp.presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=1 and v.user_id=pp.user_id and v.choice in ('A','B'))
    order by random() limit v_needed;
  end if;
  if not exists(select 1 from debate_secret_revotes where round_id=p_round_id) then
    perform public.draw_debate_secret_revote(p_round_id);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.start_debate_engine(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_host text; v_me text; v_count bigint; v_needed bigint; va bigint; vb bigint; v_twist text;
begin
 select room_id into v_room from rounds where id=p_round_id for update;
 select host_id into v_host from rooms where id=v_room;
 select player_id into v_me from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if v_me is null or v_host<>v_me then raise exception 'Host only'; end if;

 insert into debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 select p_round_id,1,p.player_id,p.user_id,v.choice
 from votes v join players p on p.player_id=v.player_id and p.room_id=v_room
 where v.round_id=p_round_id and p.abandoned_at is null
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;

 update rounds set status='debate',debate_phase='debate',vote_cycle=1,twist_request_open=true where id=p_round_id;

 if not exists(select 1 from debate_proclamations where round_id=p_round_id) then
   select count(*) into v_count from players where room_id=v_room and abandoned_at is null;
   v_needed:=floor(v_count/2.0);
   insert into debate_proclamations(round_id,proclamation_id,player_id,user_id)
   select p_round_id, prs.id, pls.player_id, pls.user_id
   from (
     select p.*,row_number() over(order by random()) rn
     from players p where p.room_id=v_room and p.abandoned_at is null and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=1 and v.user_id=p.user_id and v.choice in ('A','B'))
     order by random() limit v_needed
   ) pls
   join (
     select id,row_number() over(order by random()) rn
     from proclamations where active=true and audience='teen'
     order by random() limit v_needed
   ) prs using(rn);
 end if;

 if not exists(select 1 from debate_secret_revotes where round_id=p_round_id) then
   perform public.draw_debate_secret_revote(p_round_id);
 end if;

 select count(*) filter(where choice='A'),count(*) filter(where choice='B') into va,vb
 from debate_vote_cycles where round_id=p_round_id and cycle_number=1;

 if (va+vb)>1 and (va=0 or vb=0) then
   v_twist:=null;
 end if;
 return jsonb_build_object('votes_a',va,'votes_b',vb,'unanimous',((va+vb)>1 and (va=0 or vb=0) and not exists(select 1 from debate_vote_cycles where round_id=p_round_id and cycle_number=1 and choice='N')),'twist',v_twist);
end $function$;

CREATE OR REPLACE FUNCTION public.propose_debate_twist_vote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_open boolean;v_paused boolean;v_num bigint;v_player text;v_players bigint;
begin
 perform private.require_position(p_round_id);
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
end $function$;

CREATE OR REPLACE FUNCTION public.request_debate_twist(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_cycle bigint; v_player text; vp bigint; vr bigint; v_twist bigint;
begin
 perform private.require_position(p_round_id);
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
end $function$;

CREATE OR REPLACE FUNCTION public.propose_debate_revote(p_round_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; v_paused boolean; v_num bigint; v_status text; v_id bigint; v_player text; v_players bigint;
begin
 perform private.require_position(p_round_id);
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
end $function$;

CREATE OR REPLACE FUNCTION public.publish_debate_proclamation(p_round_id bigint, p_text text, p_scope text, p_target_player_id text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_ids text[];
begin
 perform private.require_position(p_round_id);
 if p_scope not in ('GRUPAL','DIRIGIDA') then raise exception 'Invalid proclamation audience'; end if;
 select room_id into v_room from public.rounds where id=p_round_id;
 if p_scope='GRUPAL' then
   if p_target_player_id is not null then raise exception 'Group proclamation cannot have a target'; end if;
   select array_agg(player_id order by created_at,player_id) into v_ids
   from public.players where room_id=v_room and abandoned_at is null and presence='present'
   and user_id<>auth.uid();
 else
   v_ids:=array[p_target_player_id];
 end if;
 return public.publish_debate_proclamation_to_players(p_round_id,p_text,v_ids);
end $function$;

CREATE OR REPLACE FUNCTION public.publish_debate_proclamation_to_players(p_round_id bigint, p_text text, p_recipients text[])
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_room bigint;v_phase text;v_paused boolean;v_me text;v_sender text;v_user uuid;
 v_text text;v_dp bigint;v_count integer;v_names text;v_event text;v_total integer;v_event_id bigint;
begin
 perform private.require_position(p_round_id);
 v_text:=nullif(trim(regexp_replace(coalesce(p_text,''),'[\r\n\t]+',' ','g')),'');
 if v_text is null or length(v_text)>180 then raise exception 'Proclamation must be between 1 and 180 characters'; end if;
 if p_recipients is null or coalesce(array_length(p_recipients,1),0)=0
    or array_position(p_recipients,null) is not null
    or (select count(distinct id) from unnest(p_recipients) as id)<>array_length(p_recipients,1)
 then raise exception 'Select at least one unique recipient'; end if;
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Proclamation unavailable'; end if;
 v_user:=auth.uid();
 select player_id,name into v_me,v_sender from public.players
  where room_id=v_room and user_id=v_user and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Not active'; end if;
 if v_me=any(p_recipients) then raise exception 'You cannot address a proclamation to yourself'; end if;
 select count(*),string_agg(name,', ' order by created_at,player_id)
 into v_count,v_names from public.players
 where room_id=v_room and abandoned_at is null and presence='present'
 and player_id=any(p_recipients);
 if v_count<>array_length(p_recipients,1) then raise exception 'A recipient is no longer at the table'; end if;
 select count(*) into v_total from public.players
  where room_id=v_room and abandoned_at is null and presence='present' and player_id<>v_me;
 select id into v_dp from public.debate_proclamations
  where round_id=p_round_id and player_id=v_me and used_at is null order by id limit 1 for update;
 if v_dp is null then raise exception 'No proclamation available'; end if;
 update public.debate_proclamations set used_at=now() where id=v_dp;
 v_event:=case when v_count=v_total then 'ANÓNIMO: '||v_text
   else coalesce(v_sender,'JUGADOR')||': '||v_text end;
 v_event_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
 insert into public.debate_private_proclamations(id,round_id,sender_user_id,text,reply_enabled)
 values (v_event_id,p_round_id,v_user,v_event,v_count<v_total);
 insert into public.debate_private_proclamation_recipients(proclamation_id,player_id,user_id)
 select v_event_id,p.player_id,p.user_id from public.players p
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
 and p.player_id=any(p_recipients);
 return v_event;
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
 perform private.require_position(p_round);
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
 return jsonb_build_object('server_now',clock_timestamp(),'phase',v_phase,'paused',v_paused,'present',v_presence='present','targets',v_targets,'can_propose',v_players>=3 and exists(select 1 from public.debate_vote_cycles v join public.rounds r on r.id=v.round_id where r.id=p_round and v.cycle_number=r.vote_cycle and v.user_id=auth.uid() and v.choice in ('A','B')),

 'blocked',private.limbo_blocked(v_room,auth.uid()),'until_at',m.until_at,'until_end',m.id is not null and m.duration_seconds=0,
 'proposal',case when l.status='open' then jsonb_build_object('id',l.id,'name',l.target_name,'duration',l.duration_seconds,'proposer_me',l.proposer_user_id=auth.uid(),'target_me',l.target_user_id=auth.uid(),'can_vote',v_presence='present' and auth.uid()<>l.target_user_id and auth.uid()<>l.proposer_user_id,'yes',v_yes,'no',v_no,'players',v_players-1,'mine',v_mine) else null end);
end $function$;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admission jsonb;v_limbo jsonb;v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vn bigint; v_mine text; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_next_n bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 if exists(select 1 from rounds where id=p_round_id and status='saved') then raise exception 'Saved session is frozen';end if;
 v_limbo:=private.limbo_state(p_round_id);
 v_admission:=private.admission_state(p_round_id);
 select count(*) filter(where abandoned_at is null), count(*) filter(where abandoned_at is null and presence='present'), count(*) filter(where abandoned_at is null and presence='absent'), count(*) filter(where abandoned_at is not null)
 into vtotal,vp,v_absent,v_abandoned from players where room_id=v_room;
 select count(*) filter(where choice='A'),count(*) filter(where choice='B'),count(*) filter(where choice='N') into va,vb,vn
 from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*) into vr from debate_twist_requests dtr join players p on p.player_id=dtr.player_id and p.room_id=v_room
 where dtr.round_id=p_round_id and dtr.vote_cycle=v_cycle and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where dvc.choice='A'),count(*) filter(where dvc.choice='B'),count(*) filter(where dvc.choice='N') into v_next,v_next_a,v_next_b,v_next_n from debate_vote_cycles dvc join players p on p.player_id=dvc.player_id and p.room_id=v_room
 where dvc.round_id=p_round_id and dvc.cycle_number=v_cycle+1 and p.abandoned_at is null and p.presence='present';
 select count(*),count(*) filter(where used_at is not null) into v_pro_assigned,v_pro_used from debate_proclamations where round_id=p_round_id;
 select count(*),count(*) filter(where used_at is not null),coalesce(bool_or(user_id=auth.uid() and used_at is null),false)
 into v_secret_assigned,v_secret_used,v_secret_mine from debate_secret_revotes where round_id=p_round_id;
 if v_close>0 then
   select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no
   from debate_close_votes dcv join players p on p.player_id=dcv.player_id and p.room_id=v_room
   where dcv.round_id=p_round_id and dcv.proposal_number=v_close and p.abandoned_at is null and p.presence='present';
 end if;
 select choice into v_mine from debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid();
 return jsonb_build_object('mine_choice',v_mine,'votes_n',vn,'next_votes_n',v_next_n,'phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id),'limbo_state',v_limbo,'admission_state',v_admission,'session_state',private.session_state(v_room),'resume_new_vote',exists(select 1 from private.debate_saved_sessions where round_id=p_round_id and status='resumed') and v_phase='twist' and not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle));
end $function$;

CREATE OR REPLACE FUNCTION public.get_optional_debate_revote(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_window public.debate_optional_revote_windows%rowtype;v_done boolean;v_a bigint;v_b bigint;v_n bigint;v_players bigint;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle order by id desc limit 1;
 select exists(select 1 from public.debate_optional_revote_choices where window_id=v_window.id and user_id=(select auth.uid())) into v_done;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where c.choice='A'),count(*) filter(where c.choice='B'),count(*) filter(where c.choice='N') into v_a,v_b,v_n
 from public.debate_optional_revote_choices c join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window.id and p.abandoned_at is null and p.presence='present';
 return jsonb_build_object('open',v_window.id is not null and v_window.closed_at is null,'used',v_window.id is not null and v_window.closed_at is null,
 'cycle',v_cycle,'mine_done',v_done,'votes_a',v_a,'votes_b',v_b,'votes_n',v_n,'voted',v_a+v_b+v_n,'players',v_players);
end $function$;

CREATE OR REPLACE FUNCTION public.get_debate_assistant_access(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_present boolean;
 v_players bigint;v_requests bigint;v_token boolean;v_mine boolean;v_group_used boolean;v_assigned bigint;v_used bigint;v_guide boolean;v_approved boolean;v_choice text;v_prior_guide boolean;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id;
 if v_room is null or auth.uid() is null then raise exception 'Not in debate'; end if;
 select exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') into v_present;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=public.players.user_id and v.choice in ('A','B'));
 select count(distinct r.user_id) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=p.user_id and v.choice in ('A','B'));
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid();
 select exists(select 1 from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null) into v_token;
 select exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice),
        exists(select 1 from public.debate_assistant_requests where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid() and choice=v_choice and used_at is not null)
 into v_mine,v_group_used;
 select count(*),count(*) filter(where used_at is not null) into v_assigned,v_used from public.debate_assistant_tokens where round_id=p_round_id;
 select exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle) into v_approved;
 select exists(select 1 from public.debate_assistant_guides g join public.debate_vote_cycles v
 on v.round_id=g.round_id and v.cycle_number=g.cycle_number and v.user_id=g.user_id and v.choice=g.choice
 where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid()) into v_guide;
 return jsonb_build_object('context_signature',(select md5(coalesce(context,'')) from public.rounds where id=p_round_id),'cycle',v_cycle,'players',v_players,'requests',v_requests,'approved',v_approved,
  'mine_requested',v_mine,'mine_group_used',v_group_used,'token',v_token,'mine_guide',v_guide,'assigned',v_assigned,'used',v_used,
  'can_request',not v_token and not v_mine and v_choice in ('A','B') and (not v_approved or exists(select 1 from public.debate_assistant_guides g where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid() and g.choice<>v_choice and g.status='ready')),
  'active',v_phase='debate' and not v_paused and v_present and coalesce(v_choice in ('A','B'),false));
end $function$;

CREATE OR REPLACE FUNCTION public.request_debate_assistant(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_players bigint;v_requests bigint;v_eligible bigint;v_choice text;
begin
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Help unavailable'; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 if exists(select 1 from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null) then raise exception 'Wait for revote'; end if;
 if exists(select 1 from public.debate_assistant_tokens where round_id=p_round_id and user_id=auth.uid() and used_at is null) then raise exception 'Use your drawn guide first'; end if;
 select choice into v_choice from public.debate_vote_cycles where round_id=p_round_id and cycle_number=v_cycle and user_id=auth.uid();
 if v_choice is null or v_choice not in ('A','B') then raise exception 'Vote first'; end if;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=public.players.user_id and v.choice in ('A','B'));
 select count(distinct r.user_id) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=p.user_id and v.choice in ('A','B'));
 if exists(select 1 from public.debate_assistant_approvals where round_id=p_round_id and cycle_number=v_cycle)
 and not exists(select 1 from public.debate_assistant_guides g where g.round_id=p_round_id and g.cycle_number=v_cycle and g.user_id=auth.uid() and g.choice<>v_choice and g.status='ready') then raise exception 'Request already closed'; end if;
 insert into public.debate_assistant_requests(round_id,cycle_number,user_id,choice) values(p_round_id,v_cycle,auth.uid(),v_choice) on conflict do nothing;
 select count(distinct r.user_id) into v_requests from public.debate_assistant_requests r join public.players p on p.user_id=r.user_id and p.room_id=v_room
 where r.round_id=p_round_id and r.cycle_number=v_cycle and p.abandoned_at is null and p.presence='present' and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=p.user_id and v.choice in ('A','B'));
 select count(*) into v_eligible from public.players p where p.room_id=v_room and p.abandoned_at is null and p.presence='present'
 and exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round_id and v.cycle_number=v_cycle and v.user_id=p.user_id and v.choice in ('A','B'))
 and not exists(select 1 from public.debate_assistant_tokens t where t.round_id=p_round_id and t.user_id=p.user_id and t.used_at is null);
 if v_eligible>0 and v_requests>=least(v_players/2+1,v_eligible) then
  insert into public.debate_assistant_approvals(round_id,cycle_number) values(p_round_id,v_cycle) on conflict do nothing;
 end if;
 return public.get_debate_assistant_access(p_round_id);
end $function$;

CREATE OR REPLACE FUNCTION public.cast_debate_neutral_position(p_round_id bigint,p_choice text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE r public.rounds%rowtype;pid text;old_choice text;
BEGIN
 IF p_choice IS NULL OR p_choice NOT IN ('A','B') THEN RAISE EXCEPTION 'Choose A or B';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round_id FOR UPDATE;
 IF r.id IS NULL OR r.status<>'debate' OR r.debate_phase<>'debate' OR r.paused THEN RAISE EXCEPTION 'Position unavailable';END IF;
 PERFORM private.context_guard(p_round_id);
 IF EXISTS(SELECT 1 FROM public.debate_twist_proposals WHERE round_id=r.id AND vote_cycle=r.vote_cycle AND status='open')
 OR EXISTS(SELECT 1 FROM public.debate_revote_proposals WHERE round_id=r.id AND vote_cycle=r.vote_cycle AND status='open')
 OR EXISTS(SELECT 1 FROM public.debate_optional_revote_windows WHERE round_id=r.id AND vote_cycle=r.vote_cycle AND closed_at IS NULL)
 OR EXISTS(SELECT 1 FROM public.debate_pause_proposals WHERE round_id=r.id AND status='open')
 OR EXISTS(SELECT 1 FROM public.debate_presence_requests WHERE round_id=r.id AND status='open') THEN RAISE EXCEPTION 'Another proposal must be resolved first'; END IF;
 SELECT player_id INTO pid FROM public.players WHERE room_id=r.room_id AND user_id=auth.uid() AND abandoned_at IS NULL AND presence='present';
 IF pid IS NULL THEN RAISE EXCEPTION 'Not active';END IF;
 SELECT choice INTO old_choice FROM public.debate_vote_cycles WHERE round_id=r.id AND cycle_number=r.vote_cycle AND player_id=pid FOR UPDATE;
 IF old_choice IS DISTINCT FROM 'N' THEN RAISE EXCEPTION 'Only a neutral vote may be positioned freely';END IF;
 UPDATE public.debate_vote_cycles SET choice=p_choice WHERE round_id=r.id AND cycle_number=r.vote_cycle AND player_id=pid;
END $fn$;

REVOKE ALL ON FUNCTION public.cast_debate_neutral_position(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cast_debate_neutral_position(bigint,text) TO authenticated;

-- Vote-cycle writes use checked RPCs. Preserve own-vote SELECT and initial votes API.
REVOKE INSERT,UPDATE,DELETE ON public.debate_vote_cycles FROM authenticated,anon;

NOTIFY pgrst, 'reload schema';
