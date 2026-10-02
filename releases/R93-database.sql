-- R93: private decision dialogue; existing guides and sessions are preserved.
CREATE TABLE public.private_dilemma_dialogue_turns (
 id uuid PRIMARY KEY,
 session_id uuid NOT NULL REFERENCES public.private_dilemma_sessions(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 turn_number integer NOT NULL CHECK(turn_number>0),
 message text NOT NULL CHECK(length(trim(message)) BETWEEN 1 AND 3000),
 choice text NOT NULL CHECK(choice IN('A','B','N')),
 snapshot jsonb NOT NULL CHECK(jsonb_typeof(snapshot)='object'),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','ready','error')),
 reflection text NOT NULL DEFAULT '' CHECK(length(reflection)<=700),
 question text NOT NULL DEFAULT '' CHECK(length(question)<=200),
 memory text NOT NULL DEFAULT '' CHECK(length(memory)<=1800),
 mode text CHECK(mode IN('IA','BASICA')),
 error_code text,
 lease_id uuid NOT NULL DEFAULT gen_random_uuid(),
 leased_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 attempts integer NOT NULL DEFAULT 1 CHECK(attempts BETWEEN 1 AND 3),
 model text CHECK(length(model)<=120),
 input_tokens integer CHECK(input_tokens>=0),
 cached_input_tokens integer CHECK(cached_input_tokens>=0),
 output_tokens integer CHECK(output_tokens>=0),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 completed_at timestamptz,
 UNIQUE(session_id,turn_number)
);
CREATE INDEX private_dialogue_user_recent_idx ON public.private_dilemma_dialogue_turns(user_id,leased_at DESC);
CREATE UNIQUE INDEX private_dialogue_pending_idx ON public.private_dilemma_dialogue_turns(session_id) WHERE status='pending';
ALTER TABLE public.private_dilemma_dialogue_turns ENABLE ROW LEVEL SECURITY;
CREATE POLICY private_dialogue_owner_read ON public.private_dilemma_dialogue_turns FOR SELECT TO authenticated
 USING(user_id=(SELECT auth.uid()) AND EXISTS(SELECT 1 FROM public.private_dilemma_sessions s WHERE s.id=session_id AND s.user_id=(SELECT auth.uid())));
REVOKE ALL ON public.private_dilemma_dialogue_turns FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.private_dilemma_dialogue_turns TO authenticated;
GRANT ALL ON public.private_dilemma_dialogue_turns TO service_role;

CREATE OR REPLACE FUNCTION private.prepare_private_dialogue(p_session uuid,p_request uuid,p_message text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
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
 snap:=jsonb_build_object('question',s.question,'option_a',s.option_a,'option_b',s.option_b,'choice',coalesce(s.choice,'N'),'context',s.context);
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
END $fn$;
REVOKE ALL ON FUNCTION private.prepare_private_dialogue(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.prepare_private_dialogue(uuid,uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.prepare_private_dialogue(p_session uuid,p_request uuid,p_message text) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $fn$ SELECT private.prepare_private_dialogue(p_session,p_request,p_message) $fn$;
REVOKE ALL ON FUNCTION public.prepare_private_dialogue(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.prepare_private_dialogue(uuid,uuid,text) TO authenticated;

-- Completion is service-only. Clients can read their turns but cannot forge IA replies.
CREATE OR REPLACE FUNCTION private.finish_private_dialogue(p_request uuid,p_lease uuid,p_user uuid,p_reflection text,p_question text,p_memory text,p_mode text,p_usage jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $fn$
DECLARE t public.private_dilemma_dialogue_turns%rowtype;s public.private_dilemma_sessions%rowtype;snap jsonb;
BEGIN
 SELECT * INTO s FROM public.private_dilemma_sessions WHERE id=(SELECT session_id FROM public.private_dilemma_dialogue_turns WHERE id=p_request AND user_id=p_user) AND user_id=p_user FOR UPDATE;
 IF s.id IS NULL THEN RETURN jsonb_build_object('status','discarded');END IF;
 SELECT * INTO t FROM public.private_dilemma_dialogue_turns WHERE id=p_request AND user_id=p_user FOR UPDATE;
 IF t.status<>'pending' OR t.lease_id IS DISTINCT FROM p_lease THEN RETURN jsonb_build_object('status','superseded');END IF;
 snap:=jsonb_build_object('question',s.question,'option_a',s.option_a,'option_b',s.option_b,'choice',coalesce(s.choice,'N'),'context',s.context);
 IF snap<>t.snapshot THEN
  UPDATE public.private_dilemma_dialogue_turns SET status='error',error_code='STALE_CONTEXT' WHERE id=p_request;
  RETURN jsonb_build_object('status','stale');
 END IF;
 IF p_mode IS NULL OR p_mode NOT IN('IA','BASICA') OR length(trim(coalesce(p_reflection,''))) NOT BETWEEN 1 AND 700 OR length(trim(coalesce(p_question,''))) NOT BETWEEN 1 AND 200 OR length(coalesce(p_memory,''))>1800 THEN RAISE EXCEPTION 'INVALID_RESPONSE';END IF;
 UPDATE public.private_dilemma_dialogue_turns SET status='ready',reflection=trim(p_reflection),question=trim(p_question),memory=coalesce(p_memory,''),mode=p_mode,error_code=NULL,completed_at=clock_timestamp(),model=left(p_usage->>'model',120),
 input_tokens=(p_usage->>'input_tokens')::integer,cached_input_tokens=(p_usage->>'cached_input_tokens')::integer,output_tokens=(p_usage->>'output_tokens')::integer
 WHERE id=p_request RETURNING * INTO t;
 RETURN jsonb_build_object('status','ready','turn',to_jsonb(t)-'lease_id'-'snapshot'-'memory');
END $fn$;
REVOKE ALL ON FUNCTION private.finish_private_dialogue(uuid,uuid,uuid,text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.finish_private_dialogue(uuid,uuid,uuid,text,text,text,text,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.finish_private_dialogue(p_request uuid,p_lease uuid,p_user uuid,p_reflection text,p_question text,p_memory text,p_mode text,p_usage jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $fn$ SELECT private.finish_private_dialogue(p_request,p_lease,p_user,p_reflection,p_question,p_memory,p_mode,p_usage) $fn$;
REVOKE ALL ON FUNCTION public.finish_private_dialogue(uuid,uuid,uuid,text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.finish_private_dialogue(uuid,uuid,uuid,text,text,text,text,jsonb) TO service_role;
GRANT USAGE ON SCHEMA private TO authenticated,service_role;
NOTIFY pgrst,'reload schema';
