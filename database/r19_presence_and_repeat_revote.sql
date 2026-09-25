CREATE OR REPLACE FUNCTION public.get_presence_request(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;r debate_presence_requests%rowtype;v_yes bigint;v_no bigint;v_mine text;v_name text;v_presence text;v_me text;
begin
 select room_id into v_room from rounds where id=p_round_id;
 select player_id,presence into v_me,v_presence from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null limit 1;
 if v_me is null then raise exception 'Not in room'; end if;
 select * into r from debate_presence_requests where round_id=p_round_id and status='open' order by created_at desc limit 1;
 if r.id is null then return jsonb_build_object('my_presence',v_presence); end if;
 select name into v_name from players where room_id=v_room and player_id=r.player_id;
 select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no from debate_presence_votes where request_id=r.id;
 select choice into v_mine from debate_presence_votes where request_id=r.id and player_id=v_me;
 if r.action='return' then
   v_yes:=v_yes+1;
   if v_me=r.player_id then v_mine:='YES'; end if;
 end if;
 return jsonb_build_object('id',r.id,'action',r.action,'message',r.message,'requester',v_name,'requester_id',r.player_id,'mine',v_mine,'yes',coalesce(v_yes,0),'no',coalesce(v_no,0),'my_presence',v_presence);
end $function$;

CREATE OR REPLACE FUNCTION public.cast_presence_request_vote(p_request_id bigint, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r debate_presence_requests%rowtype;v_room bigint;v_me text;v_active bigint;v_yes bigint;v_no bigint;v_need bigint;
begin
 if p_choice not in('YES','NO') then raise exception 'Invalid choice'; end if;
 select * into r from debate_presence_requests where id=p_request_id and status='open' for update;
 if r.id is null then raise exception 'Request closed'; end if;
 select room_id into v_room from rounds where id=r.round_id;
 select player_id into v_me from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Only present players vote'; end if;
 if v_me=r.player_id then raise exception 'Requester cannot vote on own request'; end if;
 insert into debate_presence_votes(id,request_id,player_id,user_id,choice) values((extract(epoch from clock_timestamp())*1000000)::bigint,p_request_id,v_me,auth.uid(),p_choice)
 on conflict(request_id,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_active from players where room_id=v_room and abandoned_at is null and presence='present';
 if r.action='return' then v_active:=v_active+1; end if;
 v_need:=floor(v_active/2.0)::bigint+1;
 select count(*) filter(where choice='YES'),count(*) filter(where choice='NO') into v_yes,v_no from debate_presence_votes where request_id=p_request_id;
 if r.action='return' then v_yes:=v_yes+1; end if;
 if v_yes>=v_need then
   update debate_presence_requests set status='accepted' where id=p_request_id;
   update players set presence=case when r.action='leave' then 'absent' else 'present' end where room_id=v_room and player_id=r.player_id and abandoned_at is null;
 elsif v_no>=v_need then update debate_presence_requests set status='rejected' where id=p_request_id;
 end if;
 return jsonb_build_object('yes',v_yes,'no',v_no,'players',v_active);
end $function$;

create unique index if not exists debate_optional_revote_windows_one_open on public.debate_optional_revote_windows(round_id,vote_cycle) where closed_at is null;
alter table public.debate_optional_revote_windows drop constraint if exists debate_optional_revote_windows_round_id_vote_cycle_key;
CREATE OR REPLACE FUNCTION public.get_optional_debate_revote(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_window public.debate_optional_revote_windows%rowtype;v_done boolean;v_a bigint;v_b bigint;v_players bigint;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id;
 if v_room is null or not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null) then raise exception 'Not in room'; end if;
 select * into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle order by id desc limit 1;
 select exists(select 1 from public.debate_optional_revote_choices where window_id=v_window.id and user_id=(select auth.uid())) into v_done;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) filter(where c.choice='A'),count(*) filter(where c.choice='B') into v_a,v_b
 from public.debate_optional_revote_choices c join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window.id and p.abandoned_at is null and p.presence='present';
 return jsonb_build_object('open',v_window.id is not null and v_window.closed_at is null,'used',v_window.id is not null and v_window.closed_at is null,
 'cycle',v_cycle,'mine_done',v_done,'votes_a',v_a,'votes_b',v_b,'voted',v_a+v_b,'players',v_players);
end $function$;
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
 insert into public.debate_optional_revote_windows(round_id,vote_cycle,opened_by)
 values(p_round_id,v_cycle,(select auth.uid())) on conflict do nothing;
end $function$;