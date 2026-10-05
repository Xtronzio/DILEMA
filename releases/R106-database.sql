-- R106: chosen or randomly drawn word handoff; anyone proposes style, majority decides.
ALTER TABLE private.debate_speech_turns DROP CONSTRAINT debate_speech_turns_source_check;
ALTER TABLE private.debate_speech_turns ADD CONSTRAINT debate_speech_turns_source_check CHECK(source IN('initial','request','automatic'));
CREATE OR REPLACE FUNCTION private.moderation_sync(p_round bigint) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;blocked boolean;last_speaker uuid;next_player public.players;now_at timestamptz:=clock_timestamp();
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
  IF t.id IS NULL THEN
   SELECT x.speaker INTO last_speaker FROM private.debate_speech_turns x WHERE x.round_id=p_round AND x.ended_at IS NOT NULL ORDER BY x.ended_at DESC,x.id DESC LIMIT 1;
   SELECT * INTO next_player FROM public.players p WHERE p.room_id=r.room_id AND p.user_id IS NOT NULL AND p.abandoned_at IS NULL AND p.presence='present' AND
    (p.user_id IS DISTINCT FROM last_speaker OR NOT EXISTS(SELECT 1 FROM public.players other WHERE other.room_id=r.room_id AND other.user_id IS NOT NULL AND other.user_id IS DISTINCT FROM last_speaker AND other.abandoned_at IS NULL AND other.presence='present')) ORDER BY random() LIMIT 1;
   IF next_player.id IS NOT NULL THEN INSERT INTO private.debate_speech_turns(round_id,generation,speaker,speaker_name,source,remaining_ms) VALUES(p_round,s.generation,next_player.user_id,next_player.name,'automatic',s.seconds*1000) RETURNING * INTO t;END IF;
  END IF;
  IF t.id IS NOT NULL THEN UPDATE private.debate_speech_turns SET status='open',started_at=now_at,deadline=now_at+remaining_ms*interval '1 millisecond' WHERE id=t.id;END IF;
 ELSIF t.deadline IS NULL THEN UPDATE private.debate_speech_turns SET deadline=now_at+t.remaining_ms*interval '1 millisecond' WHERE id=t.id;
 END IF;
END $$;;
CREATE OR REPLACE FUNCTION private.moderation_state(p_round bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 'cede_candidates',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name) ORDER BY p.name,p.user_id),'[]'::jsonb) FROM public.players p WHERE p.room_id=r.room_id AND p.user_id<>u AND p.abandoned_at IS NULL AND p.presence='present'),
 'ever_moderated',EXISTS(SELECT 1 FROM private.debate_speech_turns WHERE round_id=p_round),'results',results,'proposal',proposal,'queue',queue,
 'turn',CASE WHEN t.id IS NULL THEN NULL ELSE jsonb_build_object('id',t.id,'name',t.speaker_name,'me',t.speaker=u,'deadline',t.deadline,'remaining_ms',t.remaining_ms,'mine_rating',(SELECT score FROM private.debate_speech_ratings WHERE turn_id=t.id AND voter=u)) END,
 'can_request',active AND s.style='moderated' AND NOT s.suspended AND t.speaker IS DISTINCT FROM u AND NOT EXISTS(SELECT 1 FROM private.debate_speech_turns WHERE round_id=p_round AND speaker=u AND status='queued'),
 'can_end',active AND s.style='moderated' AND NOT s.suspended AND t.speaker=u,
 'can_rate',active AND s.style='moderated' AND NOT s.suspended AND t.id IS NOT NULL AND t.speaker<>u,
 'can_propose',active AND r.status='debate' AND r.debate_phase='debate' AND NOT r.paused AND q.id IS NULL);
END $function$;
CREATE OR REPLACE FUNCTION private.moderation_cede_word(p_round bigint,p_turn bigint,p_target uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;next_turn private.debate_speech_turns;recipient public.players;u uuid:=auth.uid();state jsonb;now_at timestamptz;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 state:=private.moderation_state(p_round);
 SELECT * INTO s FROM private.debate_moderation WHERE round_id=p_round;
 SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND status='open';
 IF u IS NULL OR NOT coalesce((state->>'can_end')::boolean,false) OR t.id IS NULL OR t.speaker<>u OR p_turn IS DISTINCT FROM t.id THEN RAISE EXCEPTION 'Not your current intervention';END IF;
 IF p_target IS NULL THEN
  SELECT * INTO recipient FROM public.players WHERE room_id=r.room_id AND user_id IS NOT NULL AND user_id<>u AND abandoned_at IS NULL AND presence='present' ORDER BY random() LIMIT 1 FOR UPDATE;
 ELSE
  SELECT * INTO recipient FROM public.players WHERE room_id=r.room_id AND user_id=p_target AND user_id<>u AND abandoned_at IS NULL AND presence='present' FOR UPDATE;
 END IF;
 IF recipient.id IS NULL THEN RAISE EXCEPTION 'No eligible recipient';END IF;
 now_at:=clock_timestamp();
 UPDATE private.debate_speech_turns SET status='spoken',deadline=NULL,ended_at=now_at WHERE id=t.id;
 SELECT * INTO next_turn FROM private.debate_speech_turns WHERE round_id=p_round AND generation=s.generation AND speaker=recipient.user_id AND status='queued' FOR UPDATE;
 IF next_turn.id IS NULL THEN
  INSERT INTO private.debate_speech_turns(round_id,generation,speaker,speaker_name,source,remaining_ms) VALUES(p_round,s.generation,recipient.user_id,recipient.name,'request',s.seconds*1000) RETURNING * INTO next_turn;
 END IF;
 UPDATE private.debate_speech_turns SET status='open',started_at=now_at,remaining_ms=s.seconds*1000,deadline=now_at+s.seconds*interval '1 second' WHERE id=next_turn.id;
 RETURN private.moderation_state(p_round);
END $$;
CREATE OR REPLACE FUNCTION public.debate_cede_word(p_round bigint,p_turn bigint,p_target uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.moderation_cede_word(p_round,p_turn,p_target); $$;
REVOKE ALL ON FUNCTION private.moderation_cede_word(bigint,bigint,uuid),public.debate_cede_word(bigint,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.moderation_cede_word(bigint,bigint,uuid),public.debate_cede_word(bigint,bigint,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.moderation_action(p_round bigint, p_action text, p_turn bigint DEFAULT NULL::bigint, p_score integer DEFAULT NULL::integer, p_style text DEFAULT NULL::text, p_seconds integer DEFAULT 90, p_proposal bigint DEFAULT NULL::bigint, p_vote boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.rounds;s private.debate_moderation;t private.debate_speech_turns;q private.debate_style_proposals;u uuid:=auth.uid();p public.players;state jsonb;
BEGIN
 SELECT * INTO r FROM public.rounds WHERE id=p_round FOR UPDATE;
 SELECT * INTO p FROM public.players WHERE room_id=r.room_id AND user_id=u AND abandoned_at IS NULL AND presence='present';
 IF u IS NULL OR p.id IS NULL THEN RAISE EXCEPTION 'Not active';END IF;
 state:=private.moderation_state(p_round);
 SELECT * INTO s FROM private.debate_moderation WHERE round_id=p_round;
 SELECT * INTO t FROM private.debate_speech_turns WHERE round_id=p_round AND status='open';
 IF p_action='cede' THEN RETURN private.moderation_cede_word(p_round,p_turn,NULL);
 ELSIF p_action='request' THEN
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
END $function$;
