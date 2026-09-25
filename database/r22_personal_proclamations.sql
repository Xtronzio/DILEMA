-- R22 · Proclamas personalizadas y sorteo tras GIRO / RE-VOTO
-- Desplegado en Supabase; este archivo reproduce el esquema y las funciones.

alter table public.debate_proclamations alter column proclamation_id drop not null;
alter table public.debate_proclamations drop constraint if exists debate_proclamations_round_id_player_id_key;
create unique index if not exists debate_proclamations_one_available
  on public.debate_proclamations (round_id, player_id) where used_at is null;

CREATE OR REPLACE FUNCTION public.cast_optional_debate_revote(p_round_id bigint, p_choice text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_cycle bigint;v_phase text;v_paused boolean;v_player text;v_window bigint;v_players bigint;v_voted bigint;
begin
 if p_choice not in ('A','B') then raise exception 'Invalid choice'; end if;
 select room_id,vote_cycle,debate_phase,paused into v_room,v_cycle,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Revote unavailable'; end if;
 select id into v_window from public.debate_optional_revote_windows where round_id=p_round_id and vote_cycle=v_cycle and closed_at is null;
 if v_window is null then raise exception 'Revote window closed'; end if;
 select player_id into v_player from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present' limit 1;
 if v_player is null then raise exception 'Not active'; end if;
 insert into public.debate_optional_revote_choices(window_id,player_id,user_id,choice)
 values(v_window,v_player,(select auth.uid()),p_choice) on conflict(window_id,player_id) do nothing;
 if not found then raise exception 'Already revoted this cycle'; end if;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
 values(p_round_id,v_cycle,v_player,(select auth.uid()),p_choice)
 on conflict(round_id,cycle_number,player_id) do update set choice=excluded.choice,user_id=excluded.user_id;
 select count(*) into v_players from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into v_voted from public.debate_optional_revote_choices c join public.players p on p.room_id=v_room and p.player_id=c.player_id
 where c.window_id=v_window and p.abandoned_at is null and p.presence='present';
 if v_players>0 and v_voted>=v_players then
   update public.debate_optional_revote_windows set closed_at=now() where id=v_window;
   perform public.draw_debate_proclamation(p_round_id);
 end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.complete_debate_revote(p_round_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint; v_cycle bigint; v_phase text; vp bigint; vv bigint;
begin
 select room_id,vote_cycle,debate_phase into v_room,v_cycle,v_phase from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'twist' then return false; end if;
 if not exists(select 1 from public.players where room_id=v_room and user_id=(select auth.uid()) and abandoned_at is null and presence='present') then raise exception 'Not active'; end if;
 select count(*) into vp from public.players where room_id=v_room and abandoned_at is null and presence='present';
 select count(*) into vv from public.debate_vote_cycles d join public.players p on p.room_id=v_room and p.player_id=d.player_id
 where d.round_id=p_round_id and d.cycle_number=v_cycle+1 and p.abandoned_at is null and p.presence='present';
 if vp=0 or vv<vp then return false; end if;
 update public.rounds set vote_cycle=v_cycle+1,debate_phase='debate',twist_request_open=true where id=p_round_id;
 delete from public.debate_twist_requests where round_id=p_round_id and vote_cycle<=v_cycle;
 perform public.draw_debate_proclamation(p_round_id);
 return true;
end $function$
;

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
 where p.room_id=v_room and p.abandoned_at is null and p.presence='present' and p.user_id is not null
 and not exists(select 1 from public.debate_proclamations d where d.round_id=p_round_id and d.player_id=p.player_id and d.used_at is null)
 order by random() limit 1;
 if v_player is null then return null; end if;
 insert into public.debate_proclamations(round_id,player_id,user_id,proclamation_id)
 values(p_round_id,v_player,v_user,null);
 return coalesce(v_name,'JUGADOR');
end $function$
;

CREATE OR REPLACE FUNCTION public.init_debate_engine(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_count bigint; v_needed bigint;
begin
  select room_id into v_room from rounds where id=p_round_id;
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
    from players pp where pp.room_id=v_room and pp.abandoned_at is null and pp.presence='present'
    order by random() limit v_needed;
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.publish_debate_proclamation(p_round_id bigint, p_text text, p_scope text, p_target_player_id text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_phase text;v_paused boolean;v_me text;v_sender text;v_target text;v_text text;v_dp bigint;v_event text;
begin
 v_text:=nullif(trim(regexp_replace(coalesce(p_text,''),'[\r\n\t]+',' ','g')),'');
 if v_text is null or length(v_text)>180 then raise exception 'Proclamation must be between 1 and 180 characters'; end if;
 if p_scope not in ('GRUPAL','DIRIGIDA') then raise exception 'Invalid proclamation audience'; end if;
 select room_id,debate_phase,paused into v_room,v_phase,v_paused from public.rounds where id=p_round_id for update;
 if v_room is null or v_phase<>'debate' or v_paused then raise exception 'Proclamation unavailable'; end if;
 select player_id,name into v_me,v_sender from public.players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_me is null then raise exception 'Not active'; end if;
 if p_scope='DIRIGIDA' then
   select name into v_target from public.players where room_id=v_room and player_id=p_target_player_id and player_id<>v_me and abandoned_at is null and presence='present' limit 1;
   if v_target is null then raise exception 'Choose another present player'; end if;
 elsif p_target_player_id is not null then raise exception 'Group proclamation cannot have a target'; end if;
 select id into v_dp from public.debate_proclamations where round_id=p_round_id and player_id=v_me and used_at is null order by id limit 1 for update;
 if v_dp is null then raise exception 'No proclamation available'; end if;
 update public.debate_proclamations set used_at=now() where id=v_dp;
 v_event:='PROCLAMA DE '||coalesce(v_sender,'JUGADOR')||case when p_scope='DIRIGIDA' then ' PARA '||v_target else ' PARA LA MESA' end||' · '||v_text;
 insert into public.debate_events(id,round_id,event_type,text) values((extract(epoch from clock_timestamp())*1000000)::bigint,p_round_id,'proclamation',v_event);
 return v_event;
end $function$
;

CREATE OR REPLACE FUNCTION public.use_debate_proclamation_text(p_round_id bigint, p_text text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 return public.publish_debate_proclamation(p_round_id,p_text,'GRUPAL',null);
end $function$
;

revoke all on function public.draw_debate_proclamation(bigint) from public, anon, authenticated;
revoke all on function public.publish_debate_proclamation(bigint,text,text,text) from public, anon;
grant execute on function public.publish_debate_proclamation(bigint,text,text,text) to authenticated;
