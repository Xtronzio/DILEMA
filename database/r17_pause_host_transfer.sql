CREATE OR REPLACE FUNCTION public.set_debate_paused(p_round_id bigint, p_paused boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_host text; v_me text; v_next_host text;
begin
 select room_id into v_room from rounds where id=p_round_id;
 select host_id into v_host from rooms where id=v_room for update;
 select player_id into v_me from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null and presence='present' limit 1;
 if v_me is null or v_host<>v_me then raise exception 'Host only'; end if;
 if p_paused then
   select player_id into v_next_host from players
   where room_id=v_room and player_id<>v_me and abandoned_at is null and presence='present'
   order by created_at,player_id limit 1;
   if v_next_host is null then raise exception 'Another present player is needed before the host can pause'; end if;
   update rooms set host_id=v_next_host where id=v_room;
 end if;
 update rounds set paused=p_paused where id=p_round_id;
end $function$
