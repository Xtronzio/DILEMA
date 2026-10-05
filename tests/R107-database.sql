-- Subtransaction sentinel rolls back all fixture users, sessions and turns.
DO $test$
DECLARE u uuid:=gen_random_uuid();other uuid:=gen_random_uuid();s uuid;r uuid:=gen_random_uuid();q uuid:=gen_random_uuid();v jsonb;finished jsonb;denied boolean;
BEGIN
 BEGIN
  INSERT INTO auth.users(id,is_anonymous) VALUES(u,true),(other,true);
  PERFORM set_config('request.jwt.claim.sub',u::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.private_dilemma_sessions(question,option_a,option_b,choice,interaction_mode) VALUES('R107 fixture','Decir la verdad','Guardar el secreto','A','training') RETURNING id INTO s;
  v:=public.prepare_private_dialogue(s,r,'Mi argumento es proteger al amigo.');
  IF v->'context'->>'interaction_mode'<>'training' OR v->'context'->>'choice'<>'A' THEN RAISE EXCEPTION 'Training not authoritative';END IF;
  IF (public.prepare_private_dialogue(s,r,'Mi argumento es proteger al amigo.'))->>'status'<>'pending' THEN RAISE EXCEPTION 'Duplicate request';END IF;
  denied:=false;BEGIN UPDATE public.private_dilemma_sessions SET interaction_mode='reflection' WHERE id=s;EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Mode switched into old history';END IF;
  EXECUTE 'RESET ROLE';
  finished:=public.finish_private_dialogue(r,(v->>'lease_id')::uuid,u,'La confianza también exige responsabilidad.','¿Qué coste aceptarías?','Memoria de entrenamiento','IA','{}');
  IF finished->>'status'<>'ready' OR finished->'turn'?'snapshot' OR finished->'turn'?'memory' OR finished->'turn'?'lease_id' THEN RAISE EXCEPTION 'Reply missing or private internals leaked';END IF;
  PERFORM set_config('request.jwt.claim.sub',other::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  denied:=false;BEGIN PERFORM public.prepare_private_dialogue(s,q,'Intrusión');EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied OR EXISTS(SELECT 1 FROM public.private_dilemma_sessions WHERE id=s) THEN RAISE EXCEPTION 'Outsider access';END IF;
  denied:=false;BEGIN PERFORM public.finish_private_dialogue(r,gen_random_uuid(),u,'Falsa respuesta','¿Falsa pregunta?','','IA','{}');EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Client may finish responses';END IF;
  EXECUTE 'RESET ROLE';PERFORM set_config('request.jwt.claim.sub',u::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  UPDATE public.private_dilemma_sessions SET choice='B' WHERE id=s;
  v:=public.prepare_private_dialogue(s,q,'Ahora defiendo la alternativa.');
  IF v->'context'->>'choice'<>'B' OR jsonb_array_length(v->'context'->'history')<>1 THEN RAISE EXCEPTION 'Posture or history lost';END IF;
  UPDATE public.private_dilemma_sessions SET context='Dato nuevo' WHERE id=s;EXECUTE 'RESET ROLE';
  IF (public.finish_private_dialogue(q,(v->>'lease_id')::uuid,u,'Respuesta antigua','¿Pregunta antigua?','','IA','{}'))->>'status'<>'stale' THEN RAISE EXCEPTION 'Stale response accepted';END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.private_dilemma_sessions(question) VALUES('Conversación abierta de siempre') RETURNING id INTO s;
  v:=public.prepare_private_dialogue(s,gen_random_uuid(),'Vamos a pensarlo.');
  IF v->'context'?'interaction_mode' THEN RAISE EXCEPTION 'Legacy reflection snapshot changed';END IF;
  denied:=false;BEGIN INSERT INTO public.private_dilemma_sessions(question,interaction_mode) VALUES('Sin opciones','training');EXCEPTION WHEN check_violation THEN denied:=true;END;
  IF NOT denied THEN RAISE EXCEPTION 'Training without positions accepted';END IF;
  EXECUTE 'RESET ROLE';
  IF has_function_privilege('anon','public.prepare_private_dialogue(uuid,uuid,text)','EXECUTE') OR has_function_privilege('authenticated','public.finish_private_dialogue(uuid,uuid,uuid,text,text,text,text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'RPC permission regression';END IF;
  RAISE EXCEPTION USING ERRCODE='ZX107',MESSAGE='Rollback R107 test fixture';
 EXCEPTION WHEN SQLSTATE 'ZX107' THEN NULL;
 END;
END $test$;
SELECT 'PASS R107: training snapshot, immutable mode, idempotency, private replies, ownership/RLS, service-only finish, changed posture/history, stale rejection, legacy reflection, required training options and RPC privileges' AS result;
