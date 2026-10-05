-- R105: shared moderation and private intervention ratings. Existing debates default to free.
ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS debate_style text NOT NULL DEFAULT 'free' CHECK(debate_style IN('free','moderated'));
ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS speech_seconds integer NOT NULL DEFAULT 90 CHECK(speech_seconds IN(60,90,120));
ALTER TABLE public.rounds ADD COLUMN IF NOT EXISTS debate_style text NOT NULL DEFAULT 'free' CHECK(debate_style IN('free','moderated'));
ALTER TABLE public.rounds ADD COLUMN IF NOT EXISTS speech_seconds integer NOT NULL DEFAULT 90 CHECK(speech_seconds IN(60,90,120));

CREATE TABLE IF NOT EXISTS private.debate_moderation (
 round_id bigint PRIMARY KEY REFERENCES public.rounds(id) ON DELETE CASCADE,
 style text NOT NULL CHECK(style IN('free','moderated')), seconds integer NOT NULL CHECK(seconds IN(60,90,120)),
 generation bigint NOT NULL DEFAULT 1, seeded boolean NOT NULL DEFAULT false, suspended boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS private.debate_speech_turns (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, round_id bigint NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
 generation bigint NOT NULL, speaker uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 speaker_name text NOT NULL, source text NOT NULL CHECK(source IN('initial','request')),
 status text NOT NULL DEFAULT 'queued' CHECK(status IN('queued','open','spoken','passed','cancelled')),
 remaining_ms integer NOT NULL CHECK(remaining_ms>=0), deadline timestamptz, started_at timestamptz, ended_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX IF NOT EXISTS debate_speech_one_open ON private.debate_speech_turns(round_id) WHERE status='open';
CREATE UNIQUE INDEX IF NOT EXISTS debate_speech_one_queued ON private.debate_speech_turns(round_id,speaker) WHERE status='queued';
CREATE INDEX IF NOT EXISTS debate_speech_round_queue ON private.debate_speech_turns(round_id,generation,status,id);
CREATE TABLE IF NOT EXISTS private.debate_speech_ratings (
 turn_id bigint NOT NULL REFERENCES private.debate_speech_turns(id) ON DELETE CASCADE,
 voter uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, score integer NOT NULL CHECK(score BETWEEN 1 AND 5),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(turn_id,voter)
);
CREATE TABLE IF NOT EXISTS private.debate_style_proposals (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, round_id bigint NOT NULL REFERENCES public.rounds(id) ON DELETE CASCADE,
 proposer uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 style text NOT NULL CHECK(style IN('free','moderated')), seconds integer NOT NULL CHECK(seconds IN(60,90,120)),
 status text NOT NULL DEFAULT 'open' CHECK(status IN('open','accepted','rejected','cancelled')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE UNIQUE INDEX IF NOT EXISTS debate_style_one_open ON private.debate_style_proposals(round_id) WHERE status='open';
CREATE TABLE IF NOT EXISTS private.debate_style_votes (
 proposal_id bigint NOT NULL REFERENCES private.debate_style_proposals(id) ON DELETE CASCADE,
 voter uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, choice boolean NOT NULL, PRIMARY KEY(proposal_id,voter)
);
ALTER TABLE private.debate_moderation ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_speech_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_speech_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_style_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.debate_style_votes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.debate_moderation,private.debate_speech_turns,private.debate_speech_ratings,private.debate_style_proposals,private.debate_style_votes FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.moderation_seed_round() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 SELECT room.debate_style,room.speech_seconds INTO new.debate_style,new.speech_seconds FROM public.rooms room WHERE room.id=new.room_id;
 RETURN new;
END $$;
DROP TRIGGER IF EXISTS r105_seed_round ON public.rounds;
CREATE TRIGGER r105_seed_round BEFORE INSERT ON public.rounds FOR EACH ROW EXECUTE FUNCTION private.moderation_seed_round();

CREATE OR REPLACE FUNCTION private.moderation_reveal_ready(p_round bigint) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.rounds r JOIN public.players p ON p.room_id=r.room_id WHERE r.id=p_round AND p.user_id=auth.uid() AND p.abandoned_at IS NULL AND p.presence='present')
 AND NOT EXISTS(SELECT 1 FROM public.rounds r JOIN public.players p ON p.room_id=r.room_id WHERE r.id=p_round AND p.abandoned_at IS NULL AND p.presence='present' AND NOT EXISTS(SELECT 1 FROM public.votes v WHERE v.round_id=r.id AND v.user_id=p.user_id));
$$;
REVOKE ALL ON FUNCTION private.moderation_reveal_ready(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.moderation_reveal_ready(bigint) TO authenticated;

-- These triggers are invoker functions so current_user still distinguishes direct REST writes from approved RPCs.
CREATE OR REPLACE FUNCTION private.moderation_guard_round() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF current_user IN('anon','authenticated') AND new.room_id IS DISTINCT FROM old.room_id THEN RAISE EXCEPTION 'Round membership cannot change';END IF;
 IF current_user='authenticated' AND old.status='voting' AND new.status='reveal'
 AND new.debate_style=old.debate_style AND new.speech_seconds=old.speech_seconds
 AND new.debate_phase IS NOT DISTINCT FROM old.debate_phase AND new.paused IS NOT DISTINCT FROM old.paused
 AND private.moderation_reveal_ready(old.id)
 THEN RETURN new;END IF;
 IF current_user IN('anon','authenticated') AND
 (new.debate_style IS DISTINCT FROM old.debate_style OR new.speech_seconds IS DISTINCT FROM old.speech_seconds OR
 ((old.debate_style='moderated' OR EXISTS(SELECT 1 FROM public.rooms WHERE id=old.room_id AND mode='debate' AND (debate_style='moderated' OR new.status='finished' OR new.debate_phase='finished'))) AND
 (new.status IS DISTINCT FROM old.status OR new.debate_phase IS DISTINCT FROM old.debate_phase OR new.paused IS DISTINCT FROM old.paused)))
 THEN RAISE EXCEPTION 'Moderated debate transitions require a table decision';END IF;
 RETURN new;
END $$;
DROP TRIGGER IF EXISTS r105_guard_round ON public.rounds;
CREATE TRIGGER r105_guard_round BEFORE UPDATE ON public.rounds FOR EACH ROW EXECUTE FUNCTION private.moderation_guard_round();
CREATE OR REPLACE FUNCTION private.moderation_guard_room() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF current_user IN('anon','authenticated') AND (new.debate_style IS DISTINCT FROM old.debate_style OR new.speech_seconds IS DISTINCT FROM old.speech_seconds) THEN
  IF old.status<>'waiting' OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=old.id AND player_id=old.host_id AND user_id=auth.uid() AND abandoned_at IS NULL) THEN RAISE EXCEPTION 'Host setup only before debate';END IF;
 END IF;
 RETURN new;
END $$;
DROP TRIGGER IF EXISTS r105_guard_room ON public.rooms;
CREATE TRIGGER r105_guard_room BEFORE UPDATE ON public.rooms FOR EACH ROW EXECUTE FUNCTION private.moderation_guard_room();

CREATE OR REPLACE FUNCTION private.moderation_style_recount(p_round bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q private.debate_style_proposals; r public.rounds; n bigint;y bigint;no bigint;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 SELECT * INTO q FROM private.debate_style_proposals WHERE round_id=p_round AND status='open' FOR UPDATE;
 IF q.id IS NULL THEN RETURN;END IF;
 IF r.status<>'debate' OR r.debate_phase<>'debate' THEN UPDATE private.debate_style_proposals SET status='cancelled' WHERE id=q.id;RETURN;END IF;
 SELECT count(*) INTO n FROM public.players WHERE room_id=r.room_id AND abandoned_at IS NULL AND presence='present';
 SELECT count(*) FILTER(WHERE v.choice),count(*) FILTER(WHERE NOT v.choice) INTO y,no FROM private.debate_style_votes v JOIN public.players p ON p.room_id=r.room_id AND p.user_id=v.voter WHERE v.proposal_id=q.id AND p.abandoned_at IS NULL AND p.presence='present';
 IF y>n/2 THEN
  UPDATE private.debate_style_proposals SET status='accepted' WHERE id=q.id;
  -- Finish any current intervention before changing style; preserve past ratings.
  UPDATE private.debate_speech_turns SET status=CASE WHEN status='open' THEN 'spoken' ELSE 'cancelled' END,ended_at=clock_timestamp(),deadline=NULL WHERE round_id=p_round AND status IN('open','queued');
  UPDATE private.debate_moderation SET style=q.style,seconds=q.seconds,generation=generation+1,seeded=false,suspended=true WHERE round_id=p_round;
  UPDATE public.rounds SET debate_style=q.style,speech_seconds=q.seconds WHERE id=p_round;
 ELSIF no>n/2 OR y+no>=n OR n=0 THEN UPDATE private.debate_style_proposals SET status='rejected' WHERE id=q.id;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION private.moderation_sync(p_round bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;blocked boolean;now_at timestamptz:=clock_timestamp();
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF r.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.rooms WHERE id=r.room_id AND mode='debate') THEN RETURN;END IF;
 INSERT INTO private.debate_moderation(round_id,style,seconds) VALUES(r.id,r.debate_style,r.speech_seconds) ON CONFLICT DO NOTHING;
 PERFORM private.moderation_style_recount(p_round);
 SELECT * INTO s FROM private.debate_moderation WHERE round_id=p_round FOR UPDATE;
 IF r.status='finished' OR r.debate_phase='finished' THEN
  UPDATE private.debate_speech_turns SET status=CASE WHEN status='open' THEN 'spoken' ELSE 'cancelled' END,deadline=NULL,ended_at=now_at WHERE round_id=p_round AND status IN('open','queued');
  UPDATE private.debate_style_proposals SET status='cancelled' WHERE round_id=p_round AND status='open';
  UPDATE private.debate_moderation SET suspended=true WHERE round_id=p_round;RETURN;
 END IF;
 IF s.style<>'moderated' THEN RETURN;END IF;
 blocked:=r.status<>'debate' OR r.debate_phase<>'debate' OR r.paused OR
 EXISTS(SELECT 1 FROM private.debate_style_proposals WHERE round_id=p_round AND status='open') OR
 EXISTS(SELECT 1 FROM private.debate_session_proposals WHERE room_id=r.room_id AND status='open') OR
 EXISTS(SELECT 1 FROM private.debate_context_requests WHERE round_id=p_round AND status IN('open','approved','review')) OR
 EXISTS(SELECT 1 FROM private.debate_limbo_proposals WHERE round_id=p_round AND status='open') OR
 EXISTS(SELECT 1 FROM public.debate_pause_proposals WHERE round_id=p_round AND status='open') OR
 EXISTS(SELECT 1 FROM public.debate_revote_proposals WHERE round_id=p_round AND vote_cycle=r.vote_cycle AND status='open') OR
 EXISTS(SELECT 1 FROM public.debate_twist_proposals WHERE round_id=p_round AND vote_cycle=r.vote_cycle AND status='open') OR
 EXISTS(SELECT 1 FROM private.debate_admissions WHERE round_id=p_round AND status='open');
 UPDATE private.debate_speech_turns t0 SET status='cancelled',deadline=NULL,ended_at=now_at WHERE t0.round_id=p_round AND t0.status IN('open','queued') AND NOT EXISTS(SELECT 1 FROM public.players p WHERE p.room_id=r.room_id AND p.user_id=t0.speaker AND p.abandoned_at IS NULL AND p.presence='present');
 IF NOT s.seeded AND NOT blocked THEN
  INSERT INTO private.debate_speech_turns(round_id,generation,speaker,speaker_name,source,remaining_ms)
  SELECT p_round,s.generation,p.user_id,p.name,'initial',s.seconds*1000 FROM public.players p WHERE p.room_id=r.room_id AND p.abandoned_at IS NULL AND p.presence='present' ORDER BY random();
  UPDATE private.debate_moderation SET seeded=true WHERE round_id=p_round;
 END IF;
 SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND status='open' FOR UPDATE;
 -- Expire once using server time; reconnecting must never replay somebody else's missed turns.
 IF t.id IS NOT NULL AND t.deadline IS NOT NULL AND t.deadline<=now_at THEN
  UPDATE private.debate_speech_turns SET status='spoken',remaining_ms=0,deadline=NULL,ended_at=now_at WHERE id=t.id;t.id:=NULL;
 END IF;
 IF blocked THEN
  IF t.id IS NOT NULL AND t.deadline IS NOT NULL THEN UPDATE private.debate_speech_turns SET remaining_ms=greatest(0,ceil(extract(epoch FROM (deadline-now_at))*1000)::integer),deadline=NULL WHERE id=t.id;END IF;
  UPDATE private.debate_moderation SET suspended=true WHERE round_id=p_round;RETURN;
 END IF;
 UPDATE private.debate_moderation SET suspended=false WHERE round_id=p_round;
 IF t.id IS NULL THEN
  SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND generation=s.generation AND status='queued' ORDER BY id LIMIT 1 FOR UPDATE;
  IF t.id IS NOT NULL THEN UPDATE private.debate_speech_turns SET status='open',started_at=now_at,deadline=now_at+remaining_ms*interval '1 millisecond' WHERE id=t.id;END IF;
 ELSIF t.deadline IS NULL THEN UPDATE private.debate_speech_turns SET deadline=now_at+t.remaining_ms*interval '1 millisecond' WHERE id=t.id;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION private.moderation_round_changed() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM private.moderation_sync(new.id);RETURN new;
END $$;
DROP TRIGGER IF EXISTS r105_moderation_round ON public.rounds;
CREATE TRIGGER r105_moderation_round AFTER UPDATE OF status,debate_phase,paused ON public.rounds FOR EACH ROW EXECUTE FUNCTION private.moderation_round_changed();

CREATE OR REPLACE FUNCTION private.moderation_state(p_round bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;q private.debate_style_proposals;u uuid:=auth.uid();active boolean;queue jsonb;results jsonb;proposal jsonb;y bigint;no bigint;n bigint;mine boolean;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u) THEN RAISE EXCEPTION 'Not in room';END IF;
 PERFORM private.moderation_sync(p_round);
 SELECT * INTO s FROM private.debate_moderation WHERE round_id=p_round;
 active:=EXISTS(SELECT 1 FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL AND presence='present');
 SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND status='open';
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'name',x.speaker_name,'me',x.speaker=u,'source',x.source) ORDER BY x.id),'[]') INTO queue FROM private.debate_speech_turns x WHERE x.round_id=p_round AND x.status='queued';
 SELECT * INTO q FROM private.debate_style_proposals WHERE round_id=p_round AND status='open';
 IF q.id IS NOT NULL THEN
  SELECT count(*) INTO n FROM public.players WHERE room_id=r.room_id AND presence='present' AND abandoned_at IS NULL;
  SELECT count(*) FILTER(WHERE v.choice),count(*) FILTER(WHERE NOT v.choice) INTO y,no FROM private.debate_style_votes v JOIN public.players p ON p.room_id=r.room_id AND p.user_id=v.voter WHERE v.proposal_id=q.id AND p.abandoned_at IS NULL AND p.presence='present';
  SELECT choice INTO mine FROM private.debate_style_votes WHERE proposal_id=q.id AND voter=u;
  proposal:=jsonb_build_object('id',q.id,'style',q.style,'seconds',q.seconds,'yes',y,'no',no,'players',n,'mine',mine,'can_vote',active AND mine IS NULL AND NOT r.paused);
 END IF;
 -- No aggregates, voter identities or other people's scores are returned before the close.
 IF r.status='finished' AND r.debate_phase='finished' THEN
  WITH per_turn AS (SELECT x.id,x.speaker,x.speaker_name,avg(v.score::numeric) score,count(v.score) votes FROM private.debate_speech_turns x LEFT JOIN private.debate_speech_ratings v ON v.turn_id=x.id WHERE x.round_id=p_round AND x.status='spoken' GROUP BY x.id),
  per_person AS (SELECT speaker,max(speaker_name) name,round(avg(score),2) score,count(*) interventions,count(score) rated_interventions,sum(votes) votes FROM per_turn GROUP BY speaker),
  ranked AS (SELECT *,CASE WHEN score IS NOT NULL THEN dense_rank() OVER(ORDER BY score DESC NULLS LAST) ELSE NULL END ranking FROM per_person)
  SELECT coalesce(jsonb_agg(jsonb_build_object('name',name,'me',speaker=u,'score',score,'interventions',interventions,'rated_interventions',rated_interventions,'votes',votes,'winner',ranking=1) ORDER BY score DESC NULLS LAST,name),'[]') INTO results FROM ranked;
 END IF;
 RETURN jsonb_build_object('style',s.style,'seconds',s.seconds,'suspended',s.suspended,'server_now',clock_timestamp(),'finished',r.status='finished' AND r.debate_phase='finished',
 'ever_moderated',EXISTS(SELECT 1 FROM private.debate_speech_turns WHERE round_id=p_round),'results',results,'proposal',proposal,'queue',queue,
 'turn',CASE WHEN t.id IS NULL THEN NULL ELSE jsonb_build_object('id',t.id,'name',t.speaker_name,'me',t.speaker=u,'deadline',t.deadline,'remaining_ms',t.remaining_ms,'mine_rating',(SELECT score FROM private.debate_speech_ratings WHERE turn_id=t.id AND voter=u)) END,
 'can_request',active AND s.style='moderated' AND NOT s.suspended AND t.speaker IS DISTINCT FROM u AND NOT EXISTS(SELECT 1 FROM private.debate_speech_turns WHERE round_id=p_round AND speaker=u AND status='queued'),
 'can_end',active AND s.style='moderated' AND NOT s.suspended AND t.speaker=u,
 'can_rate',active AND s.style='moderated' AND NOT s.suspended AND t.id IS NOT NULL AND t.speaker<>u,
 'can_propose',active AND r.status='debate' AND r.debate_phase='debate' AND NOT r.paused AND q.id IS NULL);
END $$;

CREATE OR REPLACE FUNCTION private.moderation_action(p_round bigint,p_action text,p_turn bigint DEFAULT NULL,p_score integer DEFAULT NULL,p_style text DEFAULT NULL,p_seconds integer DEFAULT 90,p_proposal bigint DEFAULT NULL,p_vote boolean DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;q private.debate_style_proposals;u uuid:=auth.uid();p public.players;state jsonb;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 SELECT * INTO p FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL AND presence='present';
 IF u IS NULL OR p.id IS NULL THEN RAISE EXCEPTION 'Not active';END IF;
 state:=private.moderation_state(p_round);
 SELECT * INTO s FROM private.debate_moderation WHERE round_id=p_round;
 SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND status='open';
 IF p_action='request' THEN
  IF s.style<>'moderated' OR s.suspended OR r.status<>'debate' THEN RAISE EXCEPTION 'Moderation unavailable';END IF;
  IF t.speaker=u OR EXISTS(SELECT 1 FROM private.debate_speech_turns WHERE round_id=p_round AND speaker=u AND status='queued') THEN RETURN state;END IF;
  INSERT INTO private.debate_speech_turns(round_id,generation,speaker,speaker_name,source,remaining_ms) VALUES(p_round,s.generation,u,p.name,'request',s.seconds*1000);
 ELSIF p_action IN('pass','cede','rate') THEN
  IF s.style<>'moderated' OR s.suspended OR t.id IS NULL OR p_turn IS DISTINCT FROM t.id OR r.status<>'debate' THEN RAISE EXCEPTION 'This intervention has finished';END IF;
  IF p_action='rate' THEN
   IF t.speaker=u THEN RAISE EXCEPTION 'Cannot rate yourself';END IF;
   IF p_score IS NULL THEN DELETE FROM private.debate_speech_ratings WHERE turn_id=t.id AND voter=u;
   ELSE
    IF p_score NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Invalid rating';END IF;
    INSERT INTO private.debate_speech_ratings(turn_id,voter,score) VALUES(t.id,u,p_score) ON CONFLICT(turn_id,voter) DO UPDATE SET score=excluded.score,updated_at=clock_timestamp();
   END IF;
  ELSE
   IF t.speaker<>u THEN RAISE EXCEPTION 'Not your turn';END IF;
   UPDATE private.debate_speech_turns SET status=CASE WHEN p_action='pass' THEN 'passed' ELSE 'spoken' END,deadline=NULL,ended_at=clock_timestamp() WHERE id=t.id;
   IF p_action='pass' THEN DELETE FROM private.debate_speech_ratings WHERE turn_id=t.id;END IF;
  END IF;
 ELSIF p_action='propose' THEN
  PERFORM private.context_guard(p_round);
  IF NOT coalesce((state->>'can_propose')::boolean,false) OR p_style IS NULL OR p_style NOT IN('free','moderated') OR p_seconds IS NULL OR p_seconds NOT IN(60,90,120) OR (p_style=s.style AND (p_style='free' OR p_seconds=s.seconds)) THEN RAISE EXCEPTION 'Invalid style proposal';END IF;
  IF EXISTS(SELECT 1 FROM public.debate_pause_proposals WHERE round_id=p_round AND status='open') OR EXISTS(SELECT 1 FROM public.debate_revote_proposals WHERE round_id=p_round AND vote_cycle=r.vote_cycle AND status='open') OR EXISTS(SELECT 1 FROM public.debate_twist_proposals WHERE round_id=p_round AND vote_cycle=r.vote_cycle AND status='open') THEN RAISE EXCEPTION 'Another proposal must be resolved first';END IF;
  INSERT INTO private.debate_style_proposals(round_id,proposer,style,seconds) VALUES(p_round,u,p_style,p_seconds) RETURNING * INTO q;
  INSERT INTO private.debate_style_votes(proposal_id,voter,choice) VALUES(q.id,u,true);
 ELSIF p_action='vote_style' THEN
  SELECT * INTO q FROM private.debate_style_proposals WHERE id=p_proposal AND round_id=p_round AND status='open' FOR UPDATE;
  IF q.id IS NULL OR r.paused OR p_vote IS NULL OR r.status<>'debate' OR r.debate_phase<>'debate' THEN RAISE EXCEPTION 'Style vote closed';END IF;
  INSERT INTO private.debate_style_votes(proposal_id,voter,choice) VALUES(q.id,u,p_vote) ON CONFLICT DO NOTHING;
 ELSE RAISE EXCEPTION 'Invalid moderation action';END IF;
 RETURN private.moderation_state(p_round);
END $$;

CREATE OR REPLACE FUNCTION public.debate_moderation_state(p_round bigint) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.moderation_state(p_round) $$;
CREATE OR REPLACE FUNCTION public.debate_moderation_action(p_round bigint,p_action text,p_turn bigint DEFAULT NULL,p_score integer DEFAULT NULL,p_style text DEFAULT NULL,p_seconds integer DEFAULT 90,p_proposal bigint DEFAULT NULL,p_vote boolean DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.moderation_action(p_round,p_action,p_turn,p_score,p_style,p_seconds,p_proposal,p_vote) $$;
REVOKE ALL ON FUNCTION public.debate_moderation_state(bigint),public.debate_moderation_action(bigint,text,bigint,integer,text,integer,bigint,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.debate_moderation_state(bigint),public.debate_moderation_action(bigint,text,bigint,integer,text,integer,bigint,boolean) TO authenticated;
REVOKE ALL ON FUNCTION private.moderation_state(bigint),private.moderation_action(bigint,text,bigint,integer,text,integer,bigint,boolean),private.moderation_sync(bigint),private.moderation_style_recount(bigint),private.moderation_seed_round(),private.moderation_guard_round(),private.moderation_guard_room(),private.moderation_round_changed() FROM PUBLIC,anon,authenticated;
-- Private schema is outside the API. Only the two checked RPC entry points need underlying EXECUTE.
GRANT EXECUTE ON FUNCTION private.moderation_state(bigint),private.moderation_action(bigint,text,bigint,integer,text,integer,bigint,boolean) TO authenticated;




-- R105 integration into existing debate locks and refresh.
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
 if exists(select 1 from private.debate_style_proposals where round_id=p_round and status='open') then raise exception 'Another proposal must be resolved first';end if;
 if exists(select 1 from private.debate_session_proposals sp join public.rounds r on r.room_id=sp.room_id where r.id=p_round and sp.status='open')
 or exists(select 1 from private.debate_context_requests where round_id=p_round and status in('open','approved','review'))
 or exists(select 1 from private.debate_limbo_proposals where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions where round_id=p_round and status='open')
 or exists(select 1 from private.debate_admissions adm join public.rounds r on r.id=adm.round_id join public.players p on p.room_id=r.room_id and p.user_id=adm.user_id where r.id=p_round and r.debate_phase='debate' and adm.status='accepted' and p.presence='present' and p.abandoned_at is null and not exists(select 1 from public.debate_vote_cycles v where v.round_id=p_round and v.cycle_number=r.vote_cycle and v.user_id=p.user_id)) then raise exception 'Another proposal must be resolved first';end if;
end $function$;
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
 return jsonb_build_object('moderation_state',private.moderation_state(p_round_id),'medicine_state',v_medicine,'mine_choice',v_mine,'votes_n',vn,'next_votes_n',v_next_n,'phase',v_phase,'cycle',v_cycle,'request_open',v_open,'players',vp,'total_active',vtotal,
 'votes_a',va,'votes_b',vb,'requests',vr,'next_votes',v_next,'next_votes_a',v_next_a,'next_votes_b',v_next_b,'close_proposal',v_close,'close_yes',coalesce(v_yes,0),'close_no',coalesce(v_no,0),'close_proposer_me',v_close_proposer=auth.uid(),
 'paused',v_paused,'absent',v_absent,'abandoned',v_abandoned,'proclamations_assigned',v_pro_assigned,'proclamations_used',v_pro_used,'secret_revotes_assigned',v_secret_assigned,'secret_revotes_used',v_secret_used,'secret_revote_mine',v_secret_mine,'context_state',private.context_state(p_round_id),'limbo_state',v_limbo,'admission_state',v_admission,'session_state',private.session_state(v_room),'resume_new_vote',exists(select 1 from private.debate_saved_sessions where round_id=p_round_id and status='resumed') and v_phase='twist' and not exists(select 1 from public.debate_twists where round_id=p_round_id and vote_cycle=v_cycle));
end $function$;
