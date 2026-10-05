-- All fixture users, sessions and turns roll back with the sentinel.
DO $test$
DECLARE u uuid:=gen_random_uuid();other uuid:=gen_random_uuid();s uuid;r uuid:=gen_random_uuid();q uuid:=gen_random_uuid();v jsonb;finished jsonb;changed integer;
BEGIN
 BEGIN
  INSERT INTO auth.users(id,is_anonymous) VALUES(u,true),(other,true);
  PERFORM set_config('request.jwt.claim.sub',u::text,true);EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.private_dilemma_sessions(question,option_a,option_b,choice,context,interaction_mode) VALUES('R109 fixture','Reabrir','Conservar','A','Contexto original','training') RETURNING id INTO s;
  v:=public.prepare_private_dialogue(s,r,'Defiendo reabrir por equidad.');EXECUTE 'RESET ROLE';
  finished:=public.finish_private_dialogue(r,(v->>'lease_id')::uuid,u,'Conservar también protege un compromiso.','¿Qué coste aceptas?','Memoria original','IA','{}');
  IF finished->>'status'<>'ready' THEN RAISE EXCEPTION 'Fixture reply failed';END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  UPDATE public.private_dilemma_sessions SET context=E'Contexto original\n\nGIRO MANUAL: Hay otra cancha confirmada.',choice='N' WHERE id=s AND user_id=u;
  GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>1 THEN RAISE EXCEPTION 'Owner cannot save giro';END IF;
  v:=public.prepare_private_dialogue(s,q,'Con el giro quiero comparar ambas opciones.');
  IF v->'context'->>'interaction_mode'<>'training' OR v->'context'->>'choice'<>'N' OR v->'context'->>'context'<>E'Contexto original\n\nGIRO MANUAL: Hay otra cancha confirmada.' OR jsonb_array_length(v->'context'->'history')<>1 THEN RAISE EXCEPTION 'Giro, neutral posture or history lost';END IF;
  PERFORM set_config('request.jwt.claim.sub',other::text,true);
  UPDATE public.private_dilemma_sessions SET context='Intrusión' WHERE id=s AND user_id=u;GET DIAGNOSTICS changed=ROW_COUNT;
  IF changed<>0 OR EXISTS(SELECT 1 FROM public.private_dilemma_dialogue_turns WHERE session_id=s) THEN RAISE EXCEPTION 'Outsider could access training';END IF;
  EXECUTE 'RESET ROLE';RAISE EXCEPTION 'R109 fixture rollback' USING ERRCODE='ZX109';
 EXCEPTION WHEN SQLSTATE 'ZX109' THEN NULL;
 END;
END $test$;
