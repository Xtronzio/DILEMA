-- R102: balance all unspent resources together; the host has no allocation preference.
CREATE OR REPLACE FUNCTION private.debate_inventory_load(p_round bigint,p_user uuid)
RETURNS bigint LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT coalesce((SELECT sum(quantity) FROM private.debate_medicine_inventory WHERE round_id=p_round AND user_id=p_user),0)
  +(SELECT count(*) FROM public.debate_proclamations WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
  +(SELECT count(*) FROM public.debate_secret_revotes WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
  +(SELECT count(*) FROM public.debate_assistant_tokens WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
$$;
REVOKE ALL ON FUNCTION private.debate_inventory_load(bigint,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.pick_inventory_recipient(p_round bigint,p_item text)
RETURNS uuid LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path='' AS $$
 WITH positioned AS MATERIALIZED (
  SELECT p.user_id,private.debate_inventory_load(p_round,p.user_id) AS load
  FROM public.players p JOIN public.rounds r ON r.room_id=p.room_id AND r.id=p_round
  JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
  WHERE p.abandoned_at IS NULL AND p.presence='present' AND p.user_id IS NOT NULL AND v.choice IN ('A','B')
 )
 SELECT p.user_id FROM positioned p
 WHERE p.load=(SELECT min(load) FROM positioned)
 AND CASE p_item
  WHEN 'proclamation' THEN NOT EXISTS(SELECT 1 FROM public.debate_proclamations i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  WHEN 'revote' THEN NOT EXISTS(SELECT 1 FROM public.debate_secret_revotes i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  WHEN 'assistant' THEN NOT EXISTS(SELECT 1 FROM public.debate_assistant_tokens i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.used_at IS NULL)
  ELSE p_item IN ('limbo','robo','senuelo','cambio','espejo','antidoto') AND NOT EXISTS(SELECT 1 FROM private.debate_medicine_inventory i WHERE i.round_id=p_round AND i.user_id=p.user_id AND i.item=p_item AND i.quantity=1)
 END
 ORDER BY random() LIMIT 1
$$;
REVOKE ALL ON FUNCTION private.pick_inventory_recipient(bigint,text) FROM PUBLIC,anon,authenticated;



CREATE OR REPLACE FUNCTION private.draw_medicines(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds; k text;u uuid;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF r.id IS NULL OR r.status<>'debate' OR r.debate_phase<>'debate' THEN RETURN;END IF;
 FOREACH k IN ARRAY ARRAY['limbo','robo','senuelo','cambio','espejo','antidoto'] LOOP
  IF EXISTS(SELECT 1 FROM private.debate_medicine_draws WHERE round_id=r.id AND cycle=r.vote_cycle AND item=k) THEN CONTINUE;END IF;
  u:=private.pick_inventory_recipient(r.id,k);
  -- Record the draw even when everyone already owns this item. No reroll after consumption.
  INSERT INTO private.debate_medicine_draws VALUES(r.id,r.vote_cycle,k,u);
  IF u IS NOT NULL THEN INSERT INTO private.debate_medicine_inventory VALUES(r.id,u,k,1)
   ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;END IF;
 END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION public.draw_debate_proclamation(p_round_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_room bigint;v_player text;v_user uuid;v_name text;v_recipient uuid;
begin
 select room_id into v_room from public.rounds where id=p_round_id for update;
 if v_room is null then raise exception 'Round not found'; end if;
 v_recipient:=private.pick_inventory_recipient(p_round_id,'proclamation');
 select p.player_id,p.user_id,p.name into v_player,v_user,v_name from public.players p
 where p.room_id=v_room and p.user_id=v_recipient;
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
declare v_room bigint; v_cycle bigint; v_player text; v_user uuid;v_recipient uuid;
begin
 select room_id,vote_cycle into v_room,v_cycle from public.rounds where id=p_round_id for update;
 if v_room is null then raise exception 'Round not found'; end if;
 v_recipient:=private.pick_inventory_recipient(p_round_id,'revote');
 select p.player_id,p.user_id into v_player,v_user from public.players p
 where p.room_id=v_room and p.user_id=v_recipient;
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
 select room_id into v_room from public.rounds where id=p_round_id for update;
 if v_room is null then return; end if;
 v_user:=private.pick_inventory_recipient(p_round_id,'assistant');
 if v_user is not null then
  insert into public.debate_assistant_tokens(round_id,user_id,grant_key)
  values(p_round_id,v_user,p_grant_key) on conflict(round_id,grant_key) do nothing;
 end if;
end $function$;

CREATE OR REPLACE FUNCTION public.start_debate_engine(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_host text; v_me text; v_count bigint; v_needed bigint;v_index bigint; va bigint; vb bigint; v_twist text;
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
   for v_index in 1..v_needed loop
    perform public.draw_debate_proclamation(p_round_id);
   end loop;
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

CREATE OR REPLACE FUNCTION public.init_debate_engine(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_room bigint; v_count bigint; v_needed bigint;v_index bigint;
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
   for v_index in 1..v_needed loop
    perform public.draw_debate_proclamation(p_round_id);
   end loop;
  end if;
  if not exists(select 1 from debate_secret_revotes where round_id=p_round_id) then
    perform public.draw_debate_secret_revote(p_round_id);
  end if;
end $function$;