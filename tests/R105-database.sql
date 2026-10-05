-- Entire test fixture is reverted by the sentinel exception. Failures roll back the migration too.
DO $test$
DECLARE users uuid[];outsider uuid;u uuid;room bigint;rd bigint;d bigint;t bigint;t2 bigint;speaking_user uuid;other uuid;view jsonb;view2 jsonb;denied boolean;count_before bigint;queue_before bigint;ms integer;pid bigint;sid bigint;result_count integer;
BEGIN
 BEGIN
  SELECT id INTO d FROM public.dilemmas WHERE option_a IS NOT NULL AND option_b IS NOT NULL LIMIT 1;
  FOR i IN 1..3 LOOP u:=gen_random_uuid();INSERT INTO auth.users(id,is_anonymous) VALUES(u,true);users:=array_append(users,u);END LOOP;
  outsider:=gen_random_uuid();INSERT INTO auth.users(id,is_anonymous) VALUES(outsider,true);
  INSERT INTO public.rooms(code,mode,host_id,expected_players,debate_style,speech_seconds) VALUES('R105-'||gen_random_uuid(),'debate',users[1]::text,3,'moderated',60) RETURNING id INTO room;
  FOR i IN 1..3 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(room,users[i]::text,users[i],'R105 participant '||i);END LOOP;
  INSERT INTO public.rounds(room_id,dilemma_id,status) VALUES(room,d,'voting') RETURNING id INTO rd;
  IF (SELECT debate_style FROM public.rounds WHERE id=rd)<>'moderated' OR (SELECT speech_seconds FROM public.rounds WHERE id=rd)<>60 THEN RAISE EXCEPTION 'Room style not copied';END IF;
  UPDATE public.rooms SET status='playing' WHERE id=room;
  FOR i IN 1..3 LOOP INSERT INTO public.votes(round_id,player_id,user_id,choice) VALUES(rd,users[i]::text,users[i],CASE WHEN i=1 THEN 'A' WHEN i=2 THEN 'B' ELSE 'N' END);END LOOP;
  PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';UPDATE public.rounds SET status='reveal' WHERE id=rd;EXECUTE 'RESET ROLE';
  PERFORM public.start_debate_engine(rd);
  view:=public.debate_moderation_state(rd);t:=(view->'turn'->>'id')::bigint;
  SELECT x.speaker INTO speaking_user FROM private.debate_speech_turns x WHERE id=t;
  SELECT x INTO other FROM unnest(users) x WHERE x<>speaking_user LIMIT 1;
  IF view->>'style'<>'moderated' OR view->>'seconds'<>'60' OR t IS NULL OR jsonb_array_length(view->'queue')<>2 OR view->'results'<>'null'::jsonb THEN RAISE EXCEPTION 'Initial moderation invalid';END IF;
  IF EXISTS(SELECT 1 FROM private.debate_medicine_inventory WHERE round_id=rd) THEN RAISE EXCEPTION 'Medicines enabled';END IF;
  PERFORM set_config('request.jwt.claim.sub',outsider::text,true);denied:=false;
  BEGIN PERFORM public.debate_moderation_state(rd);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Outsider can see debate';END IF;
  PERFORM set_config('request.jwt.claim.sub',speaking_user::text,true);denied:=false;
  BEGIN PERFORM public.debate_moderation_action(rd,'rate',t,5);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Self rating accepted';END IF;
  PERFORM set_config('request.jwt.claim.sub',other::text,true);
  PERFORM public.debate_moderation_action(rd,'request');PERFORM public.debate_moderation_action(rd,'request');
  IF (SELECT count(*) FROM private.debate_speech_turns WHERE round_id=rd AND status='queued' AND speaker=other)<>1 THEN RAISE EXCEPTION 'Duplicate request';END IF;
  denied:=false;BEGIN PERFORM public.debate_moderation_action(rd,'cede',t);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Non speaker ceded turn';END IF;
  view:=public.debate_moderation_action(rd,'rate',t,1);view:=public.debate_moderation_action(rd,'rate',t,5);
  IF view->'turn'->>'mine_rating'<>'5' OR (SELECT count(*) FROM private.debate_speech_ratings WHERE turn_id=t AND voter=other)<>1 THEN RAISE EXCEPTION 'Rating overwrite duplicated';END IF;
  PERFORM public.debate_moderation_action(rd,'rate',t,NULL);
  IF EXISTS(SELECT 1 FROM private.debate_speech_ratings WHERE turn_id=t AND voter=other) THEN RAISE EXCEPTION 'Abstention retained score';END IF;
  PERFORM public.debate_moderation_action(rd,'rate',t,5);
  PERFORM set_config('request.jwt.claim.sub',speaking_user::text,true);view:=public.debate_moderation_state(rd);
  IF view->'turn'->'mine_rating'<>'null'::jsonb OR view->'results'<>'null'::jsonb OR view::text LIKE '%"votes"%' THEN RAISE EXCEPTION 'Live ratings exposed';END IF;
  view:=public.debate_moderation_action(rd,'cede',t);t2:=(view->'turn'->>'id')::bigint;
  IF t2=t OR (SELECT status FROM private.debate_speech_turns WHERE id=t)<>'spoken' THEN RAISE EXCEPTION 'Cede failed';END IF;
  denied:=false;BEGIN PERFORM public.debate_moderation_action(rd,'cede',t);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied OR (SELECT status FROM private.debate_speech_turns WHERE id=t2)<>'open' THEN RAISE EXCEPTION 'Stale cede skipped next speaker';END IF;
  PERFORM public.debate_moderation_action(rd,'request');PERFORM public.debate_moderation_action(rd,'request');
  IF (SELECT count(*) FROM private.debate_speech_turns WHERE round_id=rd AND status='queued' AND speaker=speaking_user)<>1 THEN RAISE EXCEPTION 'Repeat request duplicated';END IF;
  -- Pause and save keep the exact same intervention, queue and votes.
  UPDATE private.debate_speech_turns SET deadline=clock_timestamp()+interval '30 seconds' WHERE id=t2;
  UPDATE public.rounds SET paused=true WHERE id=rd;
  SELECT remaining_ms INTO ms FROM private.debate_speech_turns WHERE id=t2;
  IF ms NOT BETWEEN 29000 AND 30000 OR (SELECT deadline FROM private.debate_speech_turns WHERE id=t2) IS NOT NULL THEN RAISE EXCEPTION 'Pause lost time';END IF;
  SELECT count(*) INTO queue_before FROM private.debate_speech_turns WHERE round_id=rd AND status='queued';
  SELECT count(*) INTO count_before FROM private.debate_speech_ratings WHERE turn_id=t;
  denied:=false;BEGIN PERFORM public.debate_moderation_action(rd,'rate',t2,4);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Rating while paused accepted';END IF;
  PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);view:=public.debate_session_action(room,'save');pid:=(view->'proposal'->>'id')::bigint;
  PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);PERFORM public.debate_session_action(room,'vote',NULL,pid,true);
  IF (SELECT status FROM public.rounds WHERE id=rd)<>'saved' OR (SELECT remaining_ms FROM private.debate_speech_turns WHERE id=t2)<>ms THEN RAISE EXCEPTION 'Save lost moderation';END IF;
  SELECT id INTO sid FROM private.debate_saved_sessions WHERE round_id=rd;
  view:=public.debate_session_action(room,'resume',sid);pid:=(view->'proposal'->>'id')::bigint;
  PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);PERFORM public.debate_session_action(room,'vote',NULL,pid,true);
  view:=public.debate_moderation_state(rd);
  IF (view->'turn'->>'id')::bigint<>t2 OR (SELECT count(*) FROM private.debate_speech_turns WHERE round_id=rd AND status='queued')<>queue_before OR (SELECT count(*) FROM private.debate_speech_ratings WHERE turn_id=t)<>count_before OR (SELECT remaining_ms FROM private.debate_speech_turns WHERE id=t2)<>ms THEN RAISE EXCEPTION 'Resume lost turn/queue/ratings/time';END IF;
  -- Passing deletes ratings and does not contribute to the result.
  SELECT x.speaker INTO u FROM private.debate_speech_turns x WHERE id=t2;
  SELECT x INTO other FROM unnest(users) x WHERE x<>u LIMIT 1;PERFORM set_config('request.jwt.claim.sub',other::text,true);PERFORM public.debate_moderation_action(rd,'rate',t2,1);
  PERFORM set_config('request.jwt.claim.sub',u::text,true);view:=public.debate_moderation_action(rd,'pass',t2);
  IF (SELECT status FROM private.debate_speech_turns WHERE id=t2)<>'passed' OR EXISTS(SELECT 1 FROM private.debate_speech_ratings WHERE turn_id=t2) THEN RAISE EXCEPTION 'Passed turn scored';END IF;
  t2:=(view->'turn'->>'id')::bigint;
  -- Server expires exactly one intervention and rejects late ratings.
  UPDATE private.debate_speech_turns SET deadline=clock_timestamp()-interval '1 second' WHERE id=t2;
  denied:=false;BEGIN PERFORM public.debate_moderation_action(rd,'rate',t2,3);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Late rating accepted';END IF;
  view:=public.debate_moderation_state(rd);
  IF (SELECT status FROM private.debate_speech_turns WHERE id=t2)<>'spoken' OR (view->'turn'->>'id')::bigint=t2 THEN RAISE EXCEPTION 'Server expiry failed';END IF;
  -- Absent/limbo participants are skipped; neutral participants can request and rate.
  t2:=(view->'turn'->>'id')::bigint;SELECT x.speaker INTO u FROM private.debate_speech_turns x WHERE id=t2;
  UPDATE public.players SET presence='absent' WHERE room_id=room AND user_id=u;
  PERFORM public.debate_moderation_state(rd);
  IF (SELECT status FROM private.debate_speech_turns WHERE id=t2)<>'cancelled' THEN RAISE EXCEPTION 'Absent turn kept';END IF;
  UPDATE public.players SET presence='present' WHERE room_id=room AND user_id=u;
  PERFORM set_config('request.jwt.claim.sub',users[3]::text,true);view:=public.debate_moderation_action(rd,'request');
  IF NOT (view->'turn'->>'me')::boolean THEN RAISE EXCEPTION 'Neutral cannot obtain word';END IF;
  -- Switching style needs strict majority, locks other debate actions and preserves ratings.
  PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);view:=public.debate_moderation_action(rd,'propose',NULL,NULL,'free');pid:=(view->'proposal'->>'id')::bigint;
  IF pid IS NULL OR view->'proposal'->>'yes'<>'1' OR NOT (view->>'suspended')::boolean THEN RAISE EXCEPTION 'Style proposal missing';END IF;
  denied:=false;BEGIN PERFORM private.context_guard(rd);EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Other decisions overlap style vote';END IF;
  PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);view:=public.debate_moderation_action(rd,'vote_style',NULL,NULL,NULL,90,pid,true);
  IF view->>'style'<>'free' OR (SELECT count(*) FROM private.debate_speech_ratings WHERE turn_id=t)<>count_before THEN RAISE EXCEPTION 'Switch lost ratings';END IF;
  view:=public.debate_moderation_action(rd,'propose',NULL,NULL,'moderated',120);pid:=(view->'proposal'->>'id')::bigint;
  PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);view:=public.debate_moderation_action(rd,'vote_style',NULL,NULL,NULL,90,pid,true);
  IF view->>'style'<>'moderated' OR view->>'seconds'<>'120' OR jsonb_array_length(view->'queue')<>2 THEN RAISE EXCEPTION 'New moderation round missing';END IF;
  -- Invoker API works with authenticated role and direct ratings remain inaccessible.
  BEGIN
   EXECUTE 'SET LOCAL ROLE authenticated';view:=public.debate_moderation_state(rd);
   denied:=false;BEGIN EXECUTE 'SELECT count(*) FROM private.debate_speech_ratings';EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;
   IF NOT denied THEN RAISE EXCEPTION 'Private ratings table exposed';END IF;
   denied:=false;BEGIN UPDATE public.rounds SET status='finished',debate_phase='finished' WHERE id=rd;EXCEPTION WHEN OTHERS THEN denied:=true;END;
   IF NOT denied THEN RAISE EXCEPTION 'Client forced premature results';END IF;
   EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE';RAISE;
  END;
  -- Finish by actual unanimous table close; results appear and remain visible to all members.
  PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);PERFORM public.propose_debate_close(rd);
  PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);PERFORM public.cast_debate_close_vote(rd,'YES');
  PERFORM set_config('request.jwt.claim.sub',users[3]::text,true);PERFORM public.cast_debate_close_vote(rd,'YES');
  view:=public.debate_moderation_state(rd);
  IF NOT (view->>'finished')::boolean OR jsonb_array_length(view->'results')=0 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(view->'results') x WHERE x->>'winner'='true' AND x->>'score'='5.00') THEN RAISE EXCEPTION 'Final result missing/wrong';END IF;
  IF has_function_privilege('anon','public.debate_moderation_state(bigint)','EXECUTE') OR has_table_privilege('authenticated','private.debate_speech_ratings','SELECT') THEN RAISE EXCEPTION 'Unexpected anonymous/data grant';END IF;
  RAISE SQLSTATE 'ZX105' USING MESSAGE='R105 tests passed';
 EXCEPTION WHEN SQLSTATE 'ZX105' THEN NULL;
 END;
END $test$;
SELECT 'R105 passed: seeded turns, N participation, queue idempotency, private mutable ratings, pass/cede/expiry, pause/save/resume, absences, majority switching, final result, RPC grants and direct-write guards' AS result;
