-- R104: usable pure debate; medicines reserved for game. Preserve stored inventories and existing ACLs.

CREATE OR REPLACE FUNCTION private.draw_medicines(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds; k text;u uuid;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') THEN RETURN;END IF;
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

CREATE OR REPLACE FUNCTION private.medicine_state(p_round bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;inv jsonb;m private.debate_medicine_uses;last_event jsonb;targets jsonb;u uuid:=auth.uid();positioned boolean;busy boolean;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round;
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') THEN
  RETURN jsonb_build_object('enabled',false,'inventory','{}'::jsonb,'can_launch',false,'targets','[]'::jsonb,'busy',false,'pending',NULL,'event',NULL,'server_now',clock_timestamp());
 END IF;
 PERFORM private.resolve_medicine(p_round);
 PERFORM private.draw_medicines(p_round);
 SELECT coalesce(jsonb_object_agg(item,quantity),'{}') INTO inv FROM private.debate_medicine_inventory WHERE round_id=p_round AND user_id=u;
 SELECT * INTO m FROM private.debate_medicine_uses WHERE round_id=p_round AND status='pending';
 positioned:=EXISTS(SELECT 1 FROM public.players p JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id WHERE p.room_id=r.room_id AND p.user_id=u AND p.abandoned_at IS NULL AND p.presence='present' AND v.choice IN('A','B'));
 busy:=private.admission_busy(p_round) OR r.close_proposal_number>0 AND r.debate_phase='closing' OR m.id IS NOT NULL OR
 EXISTS(SELECT 1 FROM private.debate_admissions WHERE round_id=p_round AND status='open') OR
 EXISTS(SELECT 1 FROM private.debate_admissions a JOIN public.players p ON p.room_id=r.room_id AND p.user_id=a.user_id WHERE a.round_id=p_round AND a.status='accepted' AND p.abandoned_at IS NULL AND p.presence='present' AND NOT EXISTS(SELECT 1 FROM public.debate_vote_cycles v WHERE v.round_id=p_round AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id));
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.player_id,'name',p.name,'limbo',n.cnt>=3,'positioned',v.choice IN('A','B')) ORDER BY p.created_at,p.player_id),'[]') INTO targets
 FROM public.players p LEFT JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
 CROSS JOIN (SELECT count(*) cnt FROM public.players WHERE room_id=r.room_id AND presence='present' AND abandoned_at IS NULL)n
 WHERE p.room_id=r.room_id AND p.user_id<>u AND p.abandoned_at IS NULL AND p.presence='present';
 SELECT jsonb_build_object('id',x.id,'item',x.item,'status',x.status,'defence',x.defence,'result',x.result,'sender_me',x.sender=u,'target_me',x.target=u,'finished_at',x.finished_at) INTO last_event
 FROM private.debate_medicine_uses x WHERE x.round_id=p_round AND x.status<>'pending' AND (x.sender=u OR x.target=u) ORDER BY x.finished_at DESC LIMIT 1;
 RETURN jsonb_build_object('enabled',true,'inventory',inv,'can_launch',positioned AND NOT busy AND r.debate_phase='debate' AND NOT r.paused,'targets',targets,'busy',m.id IS NOT NULL,'server_now',clock_timestamp(),
 'pending',CASE WHEN m.id IS NOT NULL THEN jsonb_build_object('id',m.id,'deadline',m.deadline,'incoming',m.target=u,'outgoing',m.sender=u,'item',CASE WHEN m.sender=u THEN m.item ELSE NULL END) ELSE NULL END,'event',last_event);
END $function$;

CREATE OR REPLACE FUNCTION private.debate_inventory_load(p_round bigint, p_user uuid)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT coalesce((SELECT sum(quantity) FROM private.debate_medicine_inventory WHERE round_id=p_round AND user_id=p_user AND EXISTS(SELECT 1 FROM public.rounds r JOIN public.rooms room ON room.id=r.room_id WHERE r.id=p_round AND room.mode='game')),0)
  +(SELECT count(*) FROM public.debate_proclamations WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
  +(SELECT count(*) FROM public.debate_secret_revotes WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
  +(SELECT count(*) FROM public.debate_assistant_tokens WHERE round_id=p_round AND user_id=p_user AND used_at IS NULL)
$function$;

CREATE OR REPLACE FUNCTION private.launch_debate_medicine(p_round bigint, p_item text, p_target text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;t public.players;u uuid:=auth.uid();m private.debate_medicine_uses;s jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') THEN RAISE EXCEPTION 'BOTIQUIN_DISABLED_IN_DEBATE';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL AND presence='present') THEN RAISE EXCEPTION 'Not active';END IF;
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_request;
 IF m.id IS NOT NULL THEN
  IF m.sender<>u OR m.round_id<>p_round OR m.item<>p_item OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=m.target AND player_id=p_target) THEN RAISE EXCEPTION 'INVALID_REQUEST';END IF;
  RETURN private.medicine_state(p_round);
 END IF;
 IF p_request IS NULL OR p_item IS NULL OR p_item NOT IN('limbo','robo','senuelo','cambio') THEN RAISE EXCEPTION 'INVALID_MEDICINE';END IF;
 PERFORM private.context_guard(p_round);PERFORM private.require_position(p_round);
 s:=private.medicine_state(p_round);
 IF NOT coalesce((s->>'can_launch')::boolean,false) THEN RAISE EXCEPTION 'Another proposal must be resolved first';END IF;
 SELECT * INTO t FROM public.players WHERE room_id=r.room_id AND player_id=p_target AND user_id<>u AND abandoned_at IS NULL AND presence='present';
 IF t.id IS NULL THEN RAISE EXCEPTION 'Target unavailable';END IF;
 IF p_item='limbo' AND (SELECT count(*) FROM public.players WHERE room_id=r.room_id AND abandoned_at IS NULL AND presence='present')<3 THEN RAISE EXCEPTION 'Limbo requires at least three present players';END IF;
 IF p_item='cambio' AND NOT EXISTS(SELECT 1 FROM public.debate_vote_cycles WHERE round_id=p_round AND cycle_number=r.vote_cycle AND user_id=t.user_id AND choice IN('A','B')) THEN RAISE EXCEPTION 'Target has no A/B position';END IF;
 UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=p_round AND user_id=u AND item=p_item AND quantity=1;
 IF NOT FOUND THEN RAISE EXCEPTION 'No medicine available';END IF;
 INSERT INTO private.debate_medicine_uses(id,round_id,cycle,sender,target,item) VALUES(p_request,p_round,r.vote_cycle,u,t.user_id,p_item);
 RETURN private.medicine_state(p_round);
END $function$;

CREATE OR REPLACE FUNCTION private.defend_debate_medicine(p_round bigint, p_use uuid, p_defence text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') THEN RAISE EXCEPTION 'BOTIQUIN_DISABLED_IN_DEBATE';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 PERFORM private.resolve_medicine(p_round);
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use AND round_id=p_round FOR UPDATE;
 IF m.id IS NULL OR m.target<>u THEN RAISE EXCEPTION 'Not the recipient';END IF;
 IF m.status<>'pending' THEN RETURN private.medicine_state(p_round);END IF;
 IF p_defence IS NULL OR p_defence NOT IN('espejo','antidoto','none') THEN RAISE EXCEPTION 'Invalid defence';END IF;
 IF p_defence<>'none' THEN
  IF NOT EXISTS(SELECT 1 FROM public.debate_vote_cycles v JOIN public.players p ON p.user_id=v.user_id AND p.room_id=r.room_id WHERE v.round_id=p_round AND v.cycle_number=r.vote_cycle AND v.user_id=u AND v.choice IN('A','B') AND p.presence='present' AND p.abandoned_at IS NULL) THEN RAISE EXCEPTION 'Choose A or B to use tools';END IF;
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=p_round AND user_id=u AND item=p_defence AND quantity=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No defence available';END IF;
 END IF;
 IF p_defence='antidoto' THEN
  copy:=CASE WHEN m.item='senuelo' THEN 'Era un señuelo. Has gastado el Antídoto en una falsa pócima.' ELSE 'El Antídoto ha neutralizado la pócima.' END;
 ELSE copy:=private.apply_medicine(m.id,p_defence='espejo');END IF;
 UPDATE private.debate_medicine_uses SET status=CASE WHEN p_defence='espejo' THEN 'reflected' WHEN p_defence='antidoto' THEN 'blocked' WHEN m.item='senuelo' THEN 'decoy' ELSE 'applied' END,
 defence=nullif(p_defence,'none'),result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 RETURN private.medicine_state(p_round);
END $function$;

CREATE OR REPLACE FUNCTION private.resolve_medicine(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 SELECT * INTO m FROM private.debate_medicine_uses WHERE round_id=p_round AND status='pending' FOR UPDATE;
 IF m.id IS NULL THEN RETURN;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') OR r.debate_phase<>'debate' OR r.status<>'debate' OR r.vote_cycle<>m.cycle OR
 NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=m.target AND abandoned_at IS NULL AND presence='present') THEN
  UPDATE private.debate_medicine_uses SET status='cancelled',result='La persona ya no está disponible. Se devuelve la pócima.',finished_at=clock_timestamp() WHERE id=m.id;
  INSERT INTO private.debate_medicine_inventory VALUES(p_round,m.sender,m.item,1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 ELSIF m.deadline<=clock_timestamp() THEN
  copy:=private.apply_medicine(m.id,false);
  UPDATE private.debate_medicine_uses SET status=CASE WHEN item='senuelo' THEN 'decoy' ELSE 'applied' END,result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 END IF;
END $function$;

CREATE OR REPLACE FUNCTION private.apply_medicine(p_use uuid, p_reflect boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m private.debate_medicine_uses;r public.rounds;p public.players;victim uuid;k text;n bigint;next_host text;
BEGIN
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use;
 SELECT * INTO r FROM public.rounds WHERE id=m.round_id;
 IF NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='game') THEN RETURN 'El botiquín está desactivado en DEBATE.';END IF;
 victim:=CASE WHEN p_reflect THEN m.sender ELSE m.target END;
 SELECT * INTO p FROM public.players WHERE room_id=r.room_id AND user_id=victim AND abandoned_at IS NULL AND presence='present';
 IF p.id IS NULL THEN RETURN 'La persona ya no está presente. La pócima no tiene efecto.';END IF;
 IF m.item='senuelo' THEN RETURN 'Era un señuelo: una falsa pócima. La defensa elegida se ha consumido.';END IF;
 IF m.item='cambio' THEN
  UPDATE public.debate_vote_cycles SET choice=CASE choice WHEN 'A' THEN 'B' ELSE 'A' END
  WHERE round_id=r.id AND cycle_number=r.vote_cycle AND user_id=victim AND choice IN('A','B');
  IF NOT FOUND THEN RETURN 'La persona no tenía una postura A/B. Su voto se mantiene.';END IF;
  RETURN 'La pócima ha cambiado la postura. El cambio de voto personal sigue disponible si se tenía.';
 ELSIF m.item='robo' THEN
  SELECT i.item INTO k FROM private.debate_medicine_inventory i WHERE i.round_id=r.id AND i.user_id=victim AND i.quantity=1
  AND NOT EXISTS(SELECT 1 FROM private.debate_medicine_inventory own WHERE own.round_id=r.id AND own.user_id=CASE WHEN p_reflect THEN m.target ELSE m.sender END AND own.item=i.item AND own.quantity=1)
  ORDER BY random() LIMIT 1 FOR UPDATE;
  IF k IS NULL THEN RETURN 'No había una pócima o píldora que se pudiera robar sin superar el límite de 1.';END IF;
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=r.id AND user_id=victim AND item=k;
  INSERT INTO private.debate_medicine_inventory VALUES(r.id,CASE WHEN p_reflect THEN m.target ELSE m.sender END,k,1)
   ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
  RETURN 'Se ha robado una pócima o píldora. El inventario ya está actualizado.';
 ELSIF m.item='limbo' THEN
  SELECT count(*) INTO n FROM public.players WHERE room_id=r.room_id AND presence='present' AND abandoned_at IS NULL;
  IF n<3 THEN RETURN 'El limbo necesita al menos tres personas presentes. La pócima no tiene efecto.';END IF;
  IF (SELECT host_id FROM public.rooms WHERE id=r.room_id)=p.player_id THEN
   SELECT player_id INTO next_host FROM public.players WHERE room_id=r.room_id AND presence='present' AND abandoned_at IS NULL AND user_id<>victim ORDER BY created_at,player_id LIMIT 1;
   UPDATE public.rooms SET host_id=next_host WHERE id=r.room_id;
  END IF;
  INSERT INTO private.debate_limbo_proposals(round_id,target_user_id,target_player_id,target_name,proposer_user_id,duration_seconds,status,accepted_at,until_at)
  VALUES(r.id,victim,p.player_id,p.name,CASE WHEN p_reflect THEN m.target ELSE m.sender END,180,'accepted',clock_timestamp(),clock_timestamp()+interval '3 minutes');
  UPDATE public.players SET presence='absent' WHERE id=p.id;
  UPDATE public.debate_presence_requests SET status='rejected' WHERE round_id=r.id AND player_id=p.player_id AND status='open';
  RETURN 'La pócima ha enviado a la persona al limbo durante 3 minutos. Después podrá solicitar volver.';
 END IF;
 RAISE EXCEPTION 'INVALID_MEDICINE';
END $function$;

CREATE OR REPLACE FUNCTION public.assign_round_roles(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_room_id bigint;
  v_is_host boolean;
  v_impostor_player_id text;
begin

  -- Obtener la sala de la ronda
  select room_id
  into v_room_id
  from rounds
  where id = p_round_id;

  if v_room_id is null then
    raise exception 'Round not found';
  end if;


  if not exists(select 1 from public.rooms where id=v_room_id and mode='game') then
    raise exception 'GAME_DISABLED_IN_DEBATE';
  end if;

  -- Solo puede hacerlo el creador de la sala
  select exists (
    select 1
    from rooms r
    join players p
      on p.player_id = r.host_id
     and p.room_id = r.id
    where r.id = v_room_id
      and p.user_id = auth.uid()
  )
  into v_is_host;

  if not v_is_host then
    raise exception 'Only the host can assign roles';
  end if;


  -- Si ya existen los jugadores de ronda, no volver a sortear
  if exists (
    select 1
    from round_players
    where round_id = p_round_id
  ) then
    return;
  end if;


  -- Elegir impostor
  select player_id
  into v_impostor_player_id
  from players
  where room_id = v_room_id
  order by random()
  limit 1;


  -- Crear roles + inventario inicial EN LA MISMA OPERACIÓN
  insert into round_players (
    round_id,
    player_id,
    user_id,
    role,
    ready,
    potions,
    pills,
    proclamations
  )
  select
    p_round_id,
    p.player_id,
    p.user_id,

    case
      when p.player_id = v_impostor_player_id
        then 'impostor'
      else 'human'
    end,

    false,

    floor(random() * 3)::bigint,
    floor(random() * 2)::bigint,
    floor(random() * 3)::bigint

  from players p
  where p.room_id = v_room_id;


  -- Garantizar que nadie quede 0 / 0 / 0
  update round_players
  set proclamations = 1
  where round_id = p_round_id
    and potions = 0
    and pills = 0
    and proclamations = 0;


  -- Solo ahora pasamos a pantalla de rol
  update rounds
  set status = 'role'
  where id = p_round_id;

end;
$function$;

CREATE OR REPLACE FUNCTION public.assign_round_inventory(p_round_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_room_id bigint;
  v_is_host boolean;
begin

  -- Obtener la sala de esta ronda
  select room_id
  into v_room_id
  from rounds
  where id = p_round_id;

  if v_room_id is null then
    raise exception 'Round not found';
  end if;


  if not exists(select 1 from public.rooms where id=v_room_id and mode='game') then
    raise exception 'GAME_DISABLED_IN_DEBATE';
  end if;

  -- Comprobar que quien ejecuta la función es el host
  select exists (
    select 1
    from rooms r
    join players p
      on p.player_id = r.host_id
     and p.room_id = r.id
    where r.id = v_room_id
      and p.user_id = auth.uid()
  )
  into v_is_host;

  if not v_is_host then
    raise exception 'Only the host can assign inventory';
  end if;


  -- Evitar volver a sortear un inventario ya asignado
  if exists (
    select 1
    from round_players
    where round_id = p_round_id
      and (
        coalesce(potions, 0) > 0
        or coalesce(pills, 0) > 0
        or coalesce(proclamations, 0) > 0
      )
  ) then
    return;
  end if;


  -- Sorteo inicial
  update round_players
  set
    potions = floor(random() * 3)::bigint,
    pills = floor(random() * 2)::bigint,
    proclamations = floor(random() * 3)::bigint
  where round_id = p_round_id;


  -- Nadie empieza completamente vacío
  update round_players
  set proclamations = 1
  where round_id = p_round_id
    and potions = 0
    and pills = 0
    and proclamations = 0;

end;
$function$;

-- Cancel pending medicines in debate without applying effects; restore consumed medicine.
DO $r104$
DECLARE rd bigint;
BEGIN
 FOR rd IN SELECT DISTINCT m.round_id FROM private.debate_medicine_uses m JOIN public.rounds r ON r.id=m.round_id JOIN public.rooms room ON room.id=r.room_id WHERE m.status='pending' AND room.mode='debate' LOOP
  PERFORM private.resolve_medicine(rd);
 END LOOP;
END $r104$;
