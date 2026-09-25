CREATE OR REPLACE FUNCTION public.propose_presence_change(p_round_id bigint, p_action text, p_message text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;v_me text;v_presence text;v_id bigint;
begin
 if p_action<>'return' then raise exception 'Only return requires table approval'; end if;
 select room_id into v_room from rounds where id=p_round_id;
 select player_id,presence into v_me,v_presence from players where room_id=v_room and user_id=auth.uid() limit 1;
 if v_me is null or v_presence<>'absent' then raise exception 'Not absent'; end if;
 if exists(select 1 from debate_presence_requests where round_id=p_round_id and player_id=v_me and status='open') then raise exception 'Request already open'; end if;
 v_id:=(extract(epoch from clock_timestamp())*1000000)::bigint;
 insert into debate_presence_requests(id,round_id,player_id,user_id,action,message) values(v_id,p_round_id,v_me,auth.uid(),'return',null);
 return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.get_presence_request(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint;r debate_presence_requests%rowtype;v_yes bigint;v_no bigint;v_mine text;v_name text;v_presence text;v_me text;
begin
 select room_id into v_room from rounds where id=p_round_id;
 select player_id,presence into v_me,v_presence from players where room_id=v_room and user_id=auth.uid() limit 1;
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
   update players set presence=case when r.action='leave' then 'absent' else 'present' end,abandoned_at=case when r.action='return' then null else abandoned_at end,farewell=case when r.action='return' then null else farewell end where room_id=v_room and player_id=r.player_id;
 elsif v_no>=v_need then update debate_presence_requests set status='rejected' where id=p_request_id;
 end if;
 return jsonb_build_object('yes',v_yes,'no',v_no,'players',v_active);
end $function$;

create or replace function public.get_abandoned_rejoin_state(p_room_id bigint) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare p public.players; r public.rooms; latest_round bigint; req public.debate_presence_requests;
begin
 if auth.uid() is null then raise exception 'No autenticado';end if;
 select * into p from public.players where room_id=p_room_id and user_id=auth.uid() order by id desc limit 1;
 select * into r from public.rooms where id=p_room_id;
 if p.id is null or r.id is null or r.mode<>'debate' then raise exception 'No perteneces a esta mesa';end if;
 select id into latest_round from public.rounds where room_id=p_room_id order by id desc limit 1;
 if latest_round is not null then
  select * into req from public.debate_presence_requests where round_id=latest_round and player_id=p.player_id and action='return' order by created_at desc limit 1;
 end if;
 return jsonb_build_object('room_status',r.status,'round_id',latest_round,'presence',p.presence,
  'abandoned',p.abandoned_at is not null,'request_status',req.status,'request_id',req.id);
end $fn$;
create or replace function public.request_abandoned_rejoin(p_room_id bigint) returns bigint
language plpgsql security definer set search_path=public as $fn$
declare p public.players; r public.rooms; latest_round bigint; open_id bigint;
begin
 if auth.uid() is null then raise exception 'No autenticado';end if;
 select * into r from public.rooms where id=p_room_id;
 select * into p from public.players where room_id=p_room_id and user_id=auth.uid() order by id desc limit 1;
 if r.id is null or r.mode<>'debate' or r.status not in ('waiting','playing') or p.id is null or p.abandoned_at is null or p.presence<>'absent' then raise exception 'Solo quien abandonó puede solicitar volver';end if;
 select id into latest_round from public.rounds where room_id=p_room_id order by id desc limit 1;
 if latest_round is null then raise exception 'Aún no existe un debate para esta sala';end if;
 select id into open_id from public.debate_presence_requests where round_id=latest_round and player_id=p.player_id and status='open' order by id desc limit 1;
 if open_id is not null then return open_id;end if;
 return public.propose_presence_change(latest_round,'return',null);
end $fn$;
revoke all on function public.get_abandoned_rejoin_state(bigint),public.request_abandoned_rejoin(bigint) from public,anon,authenticated;
grant execute on function public.get_abandoned_rejoin_state(bigint),public.request_abandoned_rejoin(bigint) to authenticated;