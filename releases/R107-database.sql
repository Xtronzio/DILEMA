-- R107: private training is persisted separately from reflective sessions.
ALTER TABLE public.private_dilemma_sessions ADD COLUMN interaction_mode text NOT NULL DEFAULT 'reflection' CHECK(interaction_mode IN('reflection','training'));
ALTER TABLE public.private_dilemma_sessions ADD CONSTRAINT training_options_required CHECK(interaction_mode<>'training' OR (length(trim(option_a))>0 AND length(trim(option_b))>0));
CREATE OR REPLACE FUNCTION private.protect_private_interaction_mode() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN IF NEW.interaction_mode IS DISTINCT FROM OLD.interaction_mode THEN RAISE EXCEPTION 'INTERACTION_MODE_IMMUTABLE';END IF;RETURN NEW;END $$;
REVOKE ALL ON FUNCTION private.protect_private_interaction_mode() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER protect_private_interaction_mode BEFORE UPDATE ON public.private_dilemma_sessions FOR EACH ROW EXECUTE FUNCTION private.protect_private_interaction_mode();
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
 IF s.interaction_mode='training' THEN snap:=snap||jsonb_build_object('interaction_mode','training');END IF;
 IF t.id IS NULL THEN
  INSERT INTO public.private_dilemma_dialogue_turns(id,session_id,user_id,turn_number,message,choice,snapshot)
  VALUES(p_request,p_session,u,coalesce((SELECT max(turn_number) FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session),0)+1,trim(p_message),coalesce(s.choice,'N'),snap) RETURNING * INTO t;
 ELSE
  UPDATE public.private_dilemma_dialogue_turns SET status='pending',error_code=NULL,lease_id=gen_random_uuid(),leased_at=clock_timestamp(),attempts=attempts+1,snapshot=snap,choice=coalesce(s.choice,'N') WHERE id=p_request RETURNING * INTO t;
 END IF;
 SELECT memory INTO latest_memory FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session AND status='ready' AND coalesce(snapshot->>'interaction_mode','reflection')=s.interaction_mode ORDER BY turn_number DESC LIMIT 1;
 SELECT coalesce(jsonb_agg(x ORDER BY x.turn_number),'[]'::jsonb) INTO recent FROM
 (SELECT turn_number,left(message,1000) AS message,choice,reflection,question,mode FROM public.private_dilemma_dialogue_turns WHERE session_id=p_session AND status='ready' AND coalesce(snapshot->>'interaction_mode','reflection')=s.interaction_mode AND turn_number<t.turn_number ORDER BY turn_number DESC LIMIT 6)x;
 RETURN jsonb_build_object('status','prepared','request_id',t.id,'lease_id',t.lease_id,'user_id',u,'context',snap||jsonb_build_object('memory',coalesce(latest_memory,''),'history',recent,'message',t.message));
END $function$;
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
 IF s.interaction_mode='training' THEN snap:=snap||jsonb_build_object('interaction_mode','training');END IF;
 IF snap<>t.snapshot THEN
  UPDATE public.private_dilemma_dialogue_turns SET status='error',error_code='STALE_CONTEXT' WHERE id=p_request;
  RETURN jsonb_build_object('status','stale');
 END IF;
 IF p_mode IS NULL OR p_mode NOT IN('IA','BASICA') OR length(trim(coalesce(p_reflection,''))) NOT BETWEEN 1 AND 700 OR length(trim(coalesce(p_question,''))) NOT BETWEEN 1 AND 200 OR length(coalesce(p_memory,''))>1800 THEN RAISE EXCEPTION 'INVALID_RESPONSE';END IF;
 UPDATE public.private_dilemma_dialogue_turns SET status='ready',reflection=trim(p_reflection),question=trim(p_question),memory=coalesce(p_memory,''),mode=p_mode,error_code=NULL,completed_at=clock_timestamp(),model=left(p_usage->>'model',120),
 input_tokens=(p_usage->>'input_tokens')::integer,cached_input_tokens=(p_usage->>'cached_input_tokens')::integer,output_tokens=(p_usage->>'output_tokens')::integer
 WHERE id=p_request RETURNING * INTO t;
 RETURN jsonb_build_object('status','ready','turn',to_jsonb(t)-'lease_id'-'snapshot'-'memory');
END $function$;
CREATE OR REPLACE FUNCTION private.claim_current_ai(p_key text, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c public.current_ai_cache; ticket uuid; n integer;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Forbidden';end if;
 if p_key !~ '^v(1|2-spain-first|3-publishers):[123]:' or length(p_key)>100 or p_user is null then raise exception 'Invalid key';end if;
 perform pg_advisory_xact_lock(hashtextextended('current-ai-budget',0));
 select * into c from public.current_ai_cache where cache_key=p_key for update;
 if c.status='ready' and c.expires_at>now() then return jsonb_build_object('status','ready','ids',c.dilemma_ids);end if;
 if c.lease_until>now() then return jsonb_build_object('status','pending');end if;
 select calls into n from public.current_ai_budget where day=current_date and owner='global';
 if coalesce(n,0)>=30 then return jsonb_build_object('status','limited');end if;
 select calls into n from public.current_ai_budget where day=current_date and owner=p_user::text;
 if coalesce(n,0)>=6 then return jsonb_build_object('status','limited');end if;
 insert into public.current_ai_budget(day,owner,calls) values(current_date,'global',1),(current_date,p_user::text,1) on conflict(day,owner) do update set calls=public.current_ai_budget.calls+1;
 ticket:=gen_random_uuid();
 insert into public.current_ai_cache(cache_key,status,lease,lease_until) values(p_key,'building',ticket,now()+interval '150 seconds') on conflict(cache_key) do update set status='building',lease=ticket,lease_until=now()+interval '150 seconds',updated_at=now();
 return jsonb_build_object('status','claimed','lease',ticket);
end $function$;
