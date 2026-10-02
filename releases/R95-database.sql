BEGIN;
-- R95: a private topic can start without predefined options.
ALTER TABLE public.private_dilemma_sessions DROP CONSTRAINT private_dilemma_sessions_option_a_check;
ALTER TABLE public.private_dilemma_sessions DROP CONSTRAINT private_dilemma_sessions_option_b_check;
ALTER TABLE public.private_dilemma_sessions ALTER COLUMN option_a SET DEFAULT '';
ALTER TABLE public.private_dilemma_sessions ALTER COLUMN option_b SET DEFAULT '';
ALTER TABLE public.private_dilemma_sessions ADD COLUMN audience text NOT NULL DEFAULT 'teen' CHECK(audience IN('kid','teen','adult'));
ALTER TABLE public.private_dilemma_sessions ADD COLUMN allow_doubt boolean NOT NULL DEFAULT true;
ALTER TABLE public.private_dilemma_sessions ADD CONSTRAINT private_optional_options CHECK(
 length(trim(option_a))<=500 AND length(trim(option_b))<=500 AND ((trim(option_a)='' AND trim(option_b)='') OR (trim(option_a)<>'' AND trim(option_b)<>'')));
ALTER TABLE public.private_dilemma_sessions ADD CONSTRAINT private_optional_choice CHECK(choice IS NULL OR (choice='N' AND allow_doubt) OR (choice IN('A','B') AND trim(option_a)<>'' AND trim(option_b)<>''));

CREATE OR REPLACE FUNCTION private.prepare_private_dialogue(p_session uuid, p_request uuid, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE s public.private_dilemma_sessions%rowtype;t public.private_dilemma_dialogue_turns%rowtype;latest_memory text;recent jsonb;snap jsonb;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED';END IF;
 IF p_request IS NULL OR length(trim(coalesce(p_message,''))) NOT BETWEEN 1 AND 3000 THEN RAISE EXCEPTION 'INVALID_MESSAGE';END IF;
 -- Serialize requests by user and session, including requests from another device.
 PERFORM pg_advisory_xact_lock(hashtextextended(u::text,93));
 SELECT * INTO s FROM public.private_dilemma_sessions WHERE id=p_session AND user_id=u FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'PRIVATE_SESSION_NOT_FOUND';END IF;
 SELECT * INTO t FROM public.private_dilemma_dialogue_turns WHERE id=p_request;
 IF t.id IS NOT NULL THEN
  IF t.user_id<>u OR t.session_id<>p_session OR t.message<>trim(p_message) THEN RAISE EXCEPTION 'INVALID_REQUEST';END IF;
  IF t.status='ready' THEN RETURN jsonb_build_object('status','ready','turn',to_jsonb(t)-'lease_id'-'snapshot'-'memory');END IF;
  IF t.status='pending' AND t.leased_at>clock_timestamp()-interval '60 seconds' THEN RETURN jsonb_build_object('status','pending','turn',to_jsonb(t)-'lease_id'-'snapshot'-'memory');END IF;
  IF t.attempts>=3 THEN RAISE EXCEPTION 'RETRY_LIMIT';END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session AND status='pending' AND id<>p_request AND leased_at>clock_timestamp()-interval '60 seconds') THEN RAISE EXCEPTION 'DIALOGUE_BUSY';END IF;
 IF (SELECT count(*) FROM public.private_dilemma_dialogue_turns WHERE user_id=u AND leased_at>clock_timestamp()-interval '60 seconds')>=8 THEN RAISE EXCEPTION 'DIALOGUE_RATE_LIMIT';END IF;
 UPDATE public.private_dilemma_dialogue_turns SET status='error',error_code='TIMEOUT' WHERE session_id=p_session AND status='pending' AND id<>p_request AND leased_at<=clock_timestamp()-interval '60 seconds';
 snap:=jsonb_build_object('question',s.question,'option_a',s.option_a,'option_b',s.option_b,'choice',coalesce(s.choice,'N'),'context',s.context,'audience',s.audience);
 IF t.id IS NULL THEN
  INSERT INTO public.private_dilemma_dialogue_turns(id,session_id,user_id,turn_number,message,choice,snapshot)
  VALUES(p_request,p_session,u,coalesce((SELECT max(turn_number) FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session),0)+1,trim(p_message),coalesce(s.choice,'N'),snap) RETURNING * INTO t;
 ELSE
  UPDATE public.private_dilemma_dialogue_turns SET status='pending',error_code=NULL,lease_id=gen_random_uuid(),leased_at=clock_timestamp(),attempts=attempts+1,snapshot=snap,choice=coalesce(s.choice,'N') WHERE id=p_request RETURNING * INTO t;
 END IF;
 SELECT memory INTO latest_memory FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session AND status='ready' ORDER BY turn_number DESC LIMIT 1;
 SELECT coalesce(jsonb_agg(x ORDER BY x.turn_number),'[]'::jsonb) INTO recent FROM
 (SELECT turn_number,left(message,1000) AS message,choice,reflection,question,mode FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session AND status='ready' AND turn_number<t.turn_number ORDER BY turn_number DESC LIMIT 6)x;
 RETURN jsonb_build_object('status','prepared','request_id',t.id,'lease_id',t.lease_id,'user_id',u,'context',snap||jsonb_build_object('memory',coalesce(latest_memory,''),'history',recent,'message',t.message));
END $function$
;

CREATE OR REPLACE FUNCTION private.finish_private_dialogue(p_request uuid, p_lease uuid, p_user uuid, p_reflection text, p_question text, p_memory text, p_mode text, p_usage jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE t public.private_dilemma_dialogue_turns%rowtype;s public.private_dilemma_sessions%rowtype;snap jsonb;
BEGIN
 SELECT * INTO s FROM public.private_dilemma_sessions WHERE id=(SELECT session_id FROM public.private_dilemma_dialogue_turns WHERE id=p_request AND user_id=p_user) AND user_id=p_user FOR UPDATE;
 IF s.id IS NULL THEN RETURN jsonb_build_object('status','discarded');END IF;
 SELECT * INTO t FROM public.private_dilemma_dialogue_turns WHERE id=p_request AND user_id=p_user FOR UPDATE;
 IF t.status<>'pending' OR t.lease_id IS DISTINCT FROM p_lease THEN RETURN jsonb_build_object('status','superseded');END IF;
 snap:=jsonb_build_object('question',s.question,'option_a',s.option_a,'option_b',s.option_b,'choice',coalesce(s.choice,'N'),'context',s.context,'audience',s.audience);
 IF snap<>t.snapshot THEN
  UPDATE public.private_dilemma_dialogue_turns SET status='error',error_code='STALE_CONTEXT' WHERE id=p_request;
  RETURN jsonb_build_object('status','stale');
 END IF;
 IF p_mode IS NULL OR p_mode NOT IN('IA','BASICA') OR length(trim(coalesce(p_reflection,''))) NOT BETWEEN 1 AND 700 OR length(trim(coalesce(p_question,''))) NOT BETWEEN 1 AND 200 OR length(coalesce(p_memory,''))>1800 THEN RAISE EXCEPTION 'INVALID_RESPONSE';END IF;
 UPDATE public.private_dilemma_dialogue_turns SET status='ready',reflection=trim(p_reflection),question=trim(p_question),memory=coalesce(p_memory,''),mode=p_mode,error_code=NULL,completed_at=clock_timestamp(),model=left(p_usage->>'model',120),
 input_tokens=(p_usage->>'input_tokens')::integer,cached_input_tokens=(p_usage->>'cached_input_tokens')::integer,output_tokens=(p_usage->>'output_tokens')::integer
 WHERE id=p_request RETURNING * INTO t;
 RETURN jsonb_build_object('status','ready','turn',to_jsonb(t)-'lease_id'-'snapshot'-'memory');
END $function$
;

-- R95: server-owned inventory, lottery and serialized potion defence.
CREATE TABLE private.debate_medicine_inventory(
 round_id bigint NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 item text NOT NULL CHECK(item IN('limbo','robo','senuelo','cambio','espejo','antidoto')),
 quantity integer NOT NULL DEFAULT 1 CHECK(quantity BETWEEN 0 AND 1),
 PRIMARY KEY(round_id,user_id,item));
CREATE TABLE private.debate_medicine_draws(
 round_id bigint NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
 cycle bigint NOT NULL,item text NOT NULL,user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 PRIMARY KEY(round_id,cycle,item));
CREATE TABLE private.debate_medicine_uses(
 id uuid PRIMARY KEY,round_id bigint NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
 cycle bigint NOT NULL,sender uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 target uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 item text NOT NULL CHECK(item IN('limbo','robo','senuelo','cambio')),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','applied','blocked','reflected','decoy','cancelled')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 deadline timestamptz NOT NULL DEFAULT clock_timestamp()+interval '20 seconds',
 finished_at timestamptz,defence text CHECK(defence IN('espejo','antidoto')),result text);
CREATE UNIQUE INDEX debate_one_pending_medicine ON private.debate_medicine_uses(round_id) WHERE status='pending';
CREATE INDEX debate_medicine_uses_history ON private.debate_medicine_uses(round_id,created_at DESC);
ALTER TABLE private.debate_medicine_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_medicine_draws ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_medicine_uses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.debate_medicine_inventory,private.debate_medicine_draws,private.debate_medicine_uses FROM public,anon,authenticated;

CREATE FUNCTION private.draw_medicines(p_round bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds; k text;u uuid;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF r.id IS NULL OR r.status<>'debate' OR r.debate_phase<>'debate' THEN RETURN;END IF;
 FOREACH k IN ARRAY ARRAY['limbo','robo','senuelo','cambio','espejo','antidoto'] LOOP
  IF EXISTS(SELECT 1 FROM private.debate_medicine_draws WHERE round_id=r.id AND cycle=r.vote_cycle AND item=k) THEN CONTINUE;END IF;
  SELECT p.user_id INTO u FROM public.players p JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
  WHERE p.room_id=r.room_id AND p.abandoned_at IS NULL AND p.presence='present' AND v.choice IN('A','B')
  AND NOT EXISTS(SELECT 1 FROM private.debate_medicine_inventory i WHERE i.round_id=r.id AND i.user_id=p.user_id AND i.item=k AND i.quantity=1)
  ORDER BY random() LIMIT 1;
  -- Record the draw even when everyone already owns this item. No reroll after consumption.
  INSERT INTO private.debate_medicine_draws VALUES(r.id,r.vote_cycle,k,u);
  IF u IS NOT NULL THEN INSERT INTO private.debate_medicine_inventory VALUES(r.id,u,k,1)
   ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;END IF;
 END LOOP;
END $$;

CREATE FUNCTION private.apply_medicine(p_use uuid,p_reflect boolean) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m private.debate_medicine_uses;r public.rounds;p public.players;victim uuid;k text;n bigint;next_host text;
BEGIN
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use;
 SELECT * INTO r FROM public.rounds WHERE id=m.round_id;
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
END $$;

CREATE FUNCTION private.resolve_medicine(p_round bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 SELECT * INTO m FROM private.debate_medicine_uses WHERE round_id=p_round AND status='pending' FOR UPDATE;
 IF m.id IS NULL THEN RETURN;END IF;
 IF r.debate_phase<>'debate' OR r.status<>'debate' OR r.vote_cycle<>m.cycle OR
 NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=m.target AND abandoned_at IS NULL AND presence='present') THEN
  UPDATE private.debate_medicine_uses SET status='cancelled',result='La persona ya no está disponible. Se devuelve la pócima.',finished_at=clock_timestamp() WHERE id=m.id;
  INSERT INTO private.debate_medicine_inventory VALUES(p_round,m.sender,m.item,1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 ELSIF m.deadline<=clock_timestamp() THEN
  copy:=private.apply_medicine(m.id,false);
  UPDATE private.debate_medicine_uses SET status=CASE WHEN item='senuelo' THEN 'decoy' ELSE 'applied' END,result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 END IF;
END $$;

CREATE FUNCTION private.medicine_state(p_round bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;inv jsonb;m private.debate_medicine_uses;last_event jsonb;targets jsonb;u uuid:=auth.uid();positioned boolean;busy boolean;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round;
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
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
 RETURN jsonb_build_object('inventory',inv,'can_launch',positioned AND NOT busy AND r.debate_phase='debate' AND NOT r.paused,'targets',targets,'busy',m.id IS NOT NULL,'server_now',clock_timestamp(),
 'pending',CASE WHEN m.id IS NOT NULL THEN jsonb_build_object('id',m.id,'deadline',m.deadline,'incoming',m.target=u,'outgoing',m.sender=u,'item',CASE WHEN m.sender=u THEN m.item ELSE NULL END) ELSE NULL END,'event',last_event);
END $$;

CREATE FUNCTION public.launch_debate_medicine(p_round bigint,p_item text,p_target text,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;t public.players;u uuid:=auth.uid();m private.debate_medicine_uses;s jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
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
END $$;

CREATE FUNCTION public.defend_debate_medicine(p_round bigint,p_use uuid,p_defence text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 PERFORM private.resolve_medicine(p_round);
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use AND round_id=p_round FOR UPDATE;
 IF m.id IS NULL OR m.target<>u THEN RAISE EXCEPTION 'Not the recipient';END IF;
 IF m.status<>'pending' THEN RETURN private.medicine_state(p_round);END IF;
 IF p_defence IS NULL OR p_defence NOT IN('espejo','antidoto','none') THEN RAISE EXCEPTION 'Invalid defence';END IF;
 IF p_defence<>'none' THEN
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=p_round AND user_id=u AND item=p_defence AND quantity=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No defence available';END IF;
 END IF;
 IF p_defence='antidoto' THEN
  copy:=CASE WHEN m.item='senuelo' THEN 'Era un señuelo. Has gastado el Antídoto en una falsa pócima.' ELSE 'El Antídoto ha neutralizado la pócima.' END;
 ELSE copy:=private.apply_medicine(m.id,p_defence='espejo');END IF;
 UPDATE private.debate_medicine_uses SET status=CASE WHEN p_defence='espejo' THEN 'reflected' WHEN p_defence='antidoto' THEN 'blocked' WHEN m.item='senuelo' THEN 'decoy' ELSE 'applied' END,
 defence=nullif(p_defence,'none'),result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 RETURN private.medicine_state(p_round);
END $$;

CREATE FUNCTION private.medicine_cycle_trigger() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF new.debate_phase='debate' AND (old.debate_phase IS DISTINCT FROM new.debate_phase OR old.vote_cycle IS DISTINCT FROM new.vote_cycle) THEN PERFORM private.draw_medicines(new.id);END IF;
 RETURN new;
END $$;
CREATE TRIGGER medicine_cycle_draw AFTER UPDATE OF debate_phase,vote_cycle ON public.rounds FOR EACH ROW EXECUTE FUNCTION private.medicine_cycle_trigger();
REVOKE ALL ON FUNCTION private.draw_medicines(bigint),private.apply_medicine(uuid,boolean),private.resolve_medicine(bigint),private.medicine_state(bigint),private.medicine_cycle_trigger() FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION public.launch_debate_medicine(bigint,text,text,uuid),public.defend_debate_medicine(bigint,uuid,text) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.launch_debate_medicine(bigint,text,text,uuid),public.defend_debate_medicine(bigint,uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION private.context_guard(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 perform 1 from public.rounds where id=p_round for update;
 perform private.resolve_medicine(p_round);
 if exists(select 1 from private.debate_medicine_uses where round_id=p_round and status='pending') then raise exception 'Another proposal must be resolved first';end if;
 if exists(select 1 from public.rounds where id=p_round and status='saved') then raise exception 'Resume the saved session first';end if;
 if exists(select 1 from private.debate_session_proposals sp join public.rounds r on r.room_id=sp.room_id where r.id=p_round and sp.status='open')
 or exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions adm join public.rounds r on r.id=adm.round_id join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where r.id=p_round and r.debate_phase='debate' and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)) then raise exception 'Another proposal must be resolved first';end if;
end $function$
;

CREATE OR REPLACE FUNCTION private.require_position(p_round bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 PERFORM 1 FROM public.rounds WHERE id=p_round FOR UPDATE;
 PERFORM private.resolve_medicine(p_round);
 IF EXISTS(SELECT 1 FROM private.debate_medicine_uses WHERE round_id=p_round AND status='pending') THEN RAISE EXCEPTION 'Another proposal must be resolved first';END IF;
 IF auth.uid() IS NULL OR NOT EXISTS(
 SELECT 1 FROM public.rounds r JOIN public.players p ON p.room_id=r.room_id
 JOIN public.debate_vote_cycles v ON v.round_id=r.id AND v.cycle_number=r.vote_cycle AND v.user_id=p.user_id
 WHERE r.id=p_round AND p.user_id=auth.uid() AND p.abandoned_at IS NULL AND p.presence='present' AND v.choice IN ('A','B'))
 THEN RAISE EXCEPTION 'Choose A or B to use tools'; END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.get_debate_state(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_medicine jsonb;v_admission jsonb;v_limbo jsonb;v_room bigint; v_cycle bigint; v_phase text; v_open boolean; v_close bigint; v_paused boolean;
vp bigint; vtotal bigint; va bigint; vb bigint; vn bigint; v_mine text; vr bigint; v_next bigint; v_next_a bigint; v_next_b bigint; v_next_n bigint; v_yes bigint; v_no bigint;
v_absent bigint; v_abandoned bigint; v_pro_assigned bigint; v_pro_used bigint; v_secret_assigned bigint; v_secret_used bigint; v_secret_mine boolean; v_close_proposer uuid;
begin
 select room_id,vote_cycle,debate_phase,twist_request_open,close_proposal_number,paused,close_proposed_by into v_room,v_cycle,v_phase,v_open,v_close,v_paused,v_close_proposer from rounds where id=p_round_id;
 if not exists(select 1 from players where room_id=v_room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 if exists(select 1 from rounds where id=p_round_id and status='saved') then raise exception 'Saved session is frozen';end if;
 v_medicine:=private.medicine_state(p_round_id);
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
 return jsonb_build_object('medicine_state',v_medicine,'mine_choice',v_mine,'votes_n',vn,'next_votes_n',v_next_n,'phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id),'limbo_state',v_limbo,'admission_state',v_admission,'session_state',private.session_state(v_room),'resume_new_vote',exists(select 1 from private.debate_saved_sessions where round_id=p_round_id and status='resumed') and v_phase='twist' and not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle));
end $function$
;

CREATE INDEX debate_medicine_inventory_user ON private.debate_medicine_inventory(user_id);
CREATE INDEX debate_medicine_draws_user ON private.debate_medicine_draws(user_id);
CREATE INDEX debate_medicine_uses_sender ON private.debate_medicine_uses(sender);
CREATE INDEX debate_medicine_uses_target ON private.debate_medicine_uses(target);

-- Keep privileged operations in the unexposed private schema.
CREATE FUNCTION private.launch_debate_medicine(p_round bigint,p_item text,p_target text,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;t public.players;u uuid:=auth.uid();m private.debate_medicine_uses;s jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
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
END $$;
CREATE OR REPLACE FUNCTION public.launch_debate_medicine(p_round bigint,p_item text,p_target text,p_request uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.launch_debate_medicine(p_round,p_item,p_target,p_request) $$;
REVOKE ALL ON FUNCTION private.launch_debate_medicine(bigint,text,text,uuid),public.launch_debate_medicine(bigint,text,text,uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION private.launch_debate_medicine(bigint,text,text,uuid),public.launch_debate_medicine(bigint,text,text,uuid) TO authenticated;
CREATE FUNCTION private.defend_debate_medicine(p_round bigint,p_use uuid,p_defence text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;m private.debate_medicine_uses;copy text;u uuid:=auth.uid();
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Not in room';END IF;
 PERFORM private.resolve_medicine(p_round);
 SELECT * INTO m FROM private.debate_medicine_uses WHERE id=p_use AND round_id=p_round FOR UPDATE;
 IF m.id IS NULL OR m.target<>u THEN RAISE EXCEPTION 'Not the recipient';END IF;
 IF m.status<>'pending' THEN RETURN private.medicine_state(p_round);END IF;
 IF p_defence IS NULL OR p_defence NOT IN('espejo','antidoto','none') THEN RAISE EXCEPTION 'Invalid defence';END IF;
 IF p_defence<>'none' THEN
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=p_round AND user_id=u AND item=p_defence AND quantity=1;
  IF NOT FOUND THEN RAISE EXCEPTION 'No defence available';END IF;
 END IF;
 IF p_defence='antidoto' THEN
  copy:=CASE WHEN m.item='senuelo' THEN 'Era un señuelo. Has gastado el Antídoto en una falsa pócima.' ELSE 'El Antídoto ha neutralizado la pócima.' END;
 ELSE copy:=private.apply_medicine(m.id,p_defence='espejo');END IF;
 UPDATE private.debate_medicine_uses SET status=CASE WHEN p_defence='espejo' THEN 'reflected' WHEN p_defence='antidoto' THEN 'blocked' WHEN m.item='senuelo' THEN 'decoy' ELSE 'applied' END,
 defence=nullif(p_defence,'none'),result=copy,finished_at=clock_timestamp() WHERE id=m.id;
 RETURN private.medicine_state(p_round);
END $$;
CREATE OR REPLACE FUNCTION public.defend_debate_medicine(p_round bigint,p_use uuid,p_defence text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.defend_debate_medicine(p_round,p_use,p_defence) $$;
REVOKE ALL ON FUNCTION private.defend_debate_medicine(bigint,uuid,text),public.defend_debate_medicine(bigint,uuid,text) FROM public,anon;
GRANT EXECUTE ON FUNCTION private.defend_debate_medicine(bigint,uuid,text),public.defend_debate_medicine(bigint,uuid,text) TO authenticated;

COMMIT;
