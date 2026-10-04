-- Run as postgres. All fixtures are rolled back inside the exception block.
DO $test$
DECLARE users uuid[];u uuid;room bigint;rd bigint;d bigint;n int;i int;j int;c int;
 lo bigint;hi bigint;total bigint;oldtotal bigint;pid bigint;sid bigint;view jsonb;denied boolean;hostwins int:=0;mid uuid;
BEGIN
 BEGIN
  SELECT id INTO d FROM public.dilemmas WHERE option_a IS NOT NULL AND option_b IS NOT NULL LIMIT 1;
  IF d IS NULL THEN RAISE EXCEPTION 'Missing dilemma fixture';END IF;
  FOR n IN 2..8 LOOP
   FOR j IN 1..8 LOOP
    users:=ARRAY[]::uuid[];
    FOR i IN 1..n LOOP
     u:=gen_random_uuid();INSERT INTO auth.users(id,is_anonymous) VALUES(u,true);users:=array_append(users,u);
    END LOOP;
    INSERT INTO public.rooms(code,mode,host_id,expected_players) VALUES('R103-'||gen_random_uuid(),'debate',users[1]::text,n) RETURNING id INTO room;
    FOR i IN 1..n LOOP
     INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(room,users[i]::text,users[i],'R103 test '||i);
    END LOOP;
    INSERT INTO public.rounds(room_id,dilemma_id,status) VALUES(room,d,'debate') RETURNING id INTO rd;
    UPDATE public.rooms SET status='playing' WHERE id=room;
    FOR i IN 1..n LOOP
     INSERT INTO public.votes(round_id,player_id,user_id,choice) VALUES(rd,users[i]::text,users[i],CASE WHEN j%2=1 AND i=n THEN 'N' WHEN i%2=0 THEN 'B' ELSE 'A' END);
    END LOOP;
    PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);
    IF j%2=0 THEN PERFORM public.start_debate_engine(rd);ELSE PERFORM public.init_debate_engine(rd);END IF;
    SELECT min(x),max(x),sum(x) INTO lo,hi,total FROM (SELECT private.debate_inventory_load(rd,v) x FROM unnest(users) v) q;
    IF j%2=1 THEN
     PERFORM set_config('request.jwt.claim.sub',users[n]::text,true);
     IF (private.medicine_state(rd)->>'can_launch')::boolean THEN RAISE EXCEPTION 'Neutral can launch';END IF;
     IF private.debate_inventory_load(rd,users[n])=0 THEN RAISE EXCEPTION 'Neutral got no inventory';END IF;
    END IF;
    IF hi-lo>1 OR total<>8+floor(n/2.0) THEN RAISE EXCEPTION 'Initial imbalance n=%,lo=%,hi=%,total=%',n,lo,hi,total;END IF;
    IF n=2 AND private.debate_inventory_load(rd,users[1])>private.debate_inventory_load(rd,users[2]) THEN hostwins:=hostwins+1;END IF;
    FOR c IN 2..4 LOOP
     INSERT INTO public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice)
      SELECT rd,c,player_id,user_id,choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1;
     UPDATE public.rounds SET vote_cycle=c WHERE id=rd;
     PERFORM public.draw_debate_proclamation(rd);PERFORM public.draw_debate_secret_revote(rd);
     SELECT min(x),max(x),sum(x) INTO lo,hi,total FROM (SELECT private.debate_inventory_load(rd,v) x FROM unnest(users) v) q;
     IF hi-lo>1 THEN RAISE EXCEPTION 'Later imbalance n=%,cycle=%,lo=%,hi=%',n,c,lo,hi;END IF;
    END LOOP;
    oldtotal:=total;
    PERFORM private.draw_medicines(rd);PERFORM public.draw_debate_assistant(rd,'cycle:1');
    SELECT sum(private.debate_inventory_load(rd,v)) INTO total FROM unnest(users) v;
    IF total<>oldtotal THEN RAISE EXCEPTION 'Repeated draw duplicated tools';END IF;
    UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=rd AND item='limbo';
    PERFORM private.draw_medicines(rd);
    IF EXISTS(SELECT 1 FROM private.debate_medicine_inventory WHERE round_id=rd AND item='limbo' AND quantity<>0) THEN RAISE EXCEPTION 'Consumed medicine rerolled';END IF;
    -- Use the last fixture for session decisions. Odd/even mesa sizes cover strict majority and ties.
    IF j=8 AND n IN(2,3,4) THEN
     UPDATE public.rounds SET paused=true,context='R103 preserved context' WHERE id=rd;
     PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);
     view:=public.debate_session_action(room,'save');pid:=(view->'proposal'->>'id')::bigint;
     IF pid IS NULL OR (view->'proposal'->>'yes')::int<>1 THEN RAISE EXCEPTION 'Nonhost save failed';END IF;
     PERFORM set_config('request.jwt.claim.sub',users[1]::text,true);
     view:=public.debate_session_action(room,'vote',NULL,pid,n<>2);
     IF n=2 THEN
      IF (SELECT status FROM private.debate_session_proposals WHERE id=pid)<>'rejected' THEN RAISE EXCEPTION 'Tie should reject';END IF;
     ELSIF n=4 THEN
      IF view->'proposal'='null'::jsonb THEN RAISE EXCEPTION 'Half must not approve';END IF;
      PERFORM set_config('request.jwt.claim.sub',users[3]::text,true);PERFORM public.debate_session_action(room,'vote',NULL,pid,false);
      PERFORM set_config('request.jwt.claim.sub',users[4]::text,true);PERFORM public.debate_session_action(room,'vote',NULL,pid,false);
      IF (SELECT status FROM private.debate_session_proposals WHERE id=pid)<>'rejected' THEN RAISE EXCEPTION '2-2 must reject';END IF;
     ELSE
      IF view->>'room_status'<>'waiting' OR (SELECT status FROM public.rounds WHERE id=rd)<>'saved' OR (SELECT active_round_id FROM public.rooms WHERE id=room) IS NOT NULL THEN RAISE EXCEPTION '2 of 3 must save and return to hall';END IF;
      SELECT id INTO sid FROM private.debate_saved_sessions WHERE round_id=rd;
      IF (SELECT context FROM public.rounds WHERE id=rd)<>'R103 preserved context' THEN RAISE EXCEPTION 'Context lost';END IF;
      SELECT sum(private.debate_inventory_load(rd,v)) INTO oldtotal FROM unnest(users) v;
      view:=public.debate_session_action(room,'resume',sid);pid:=(view->'proposal'->>'id')::bigint;
      PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);view:=public.debate_session_action(room,'vote',NULL,pid,true);
      IF view->>'room_status'<>'playing' OR (SELECT paused FROM public.rounds WHERE id=rd) OR (SELECT debate_phase FROM public.rounds WHERE id=rd)<>'debate' THEN RAISE EXCEPTION 'Resume failed';END IF;
      SELECT sum(private.debate_inventory_load(rd,v)) INTO total FROM unnest(users) v;
      IF total<>oldtotal THEN RAISE EXCEPTION 'Resume changed inventory';END IF;
     END IF;
     UPDATE public.rounds SET paused=false WHERE id=rd;
     denied:=false;BEGIN PERFORM public.debate_session_action(room,'save');EXCEPTION WHEN OTHERS THEN denied:=true;END;
     IF NOT denied THEN RAISE EXCEPTION 'Unpaused save allowed';END IF;
     UPDATE public.rounds SET paused=true WHERE id=rd;
     UPDATE public.players SET presence='absent' WHERE room_id=room AND user_id=users[2];
     PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);
     denied:=false;BEGIN PERFORM public.debate_session_action(room,'save');EXCEPTION WHEN OTHERS THEN denied:=true;END;
     IF NOT denied THEN RAISE EXCEPTION 'Absent save allowed';END IF;
    END IF;
   END LOOP;
  END LOOP;
  -- Neutral participants receive tools; absent and abandoned participants do not.
  UPDATE public.players SET presence='absent' WHERE room_id=room AND user_id=users[3];
  UPDATE public.players SET abandoned_at=now() WHERE room_id=room AND user_id=users[4];
  UPDATE public.debate_vote_cycles SET choice='N' WHERE round_id=rd AND cycle_number=4 AND user_id=users[2];
  UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=rd;
  UPDATE public.debate_proclamations SET used_at=now() WHERE round_id=rd;
  UPDATE public.debate_secret_revotes SET used_at=now() WHERE round_id=rd;
  UPDATE public.debate_assistant_tokens SET used_at=now() WHERE round_id=rd;
  INSERT INTO private.debate_medicine_inventory(round_id,user_id,item,quantity)
   SELECT rd,users[1],k,1 FROM unnest(ARRAY['limbo','robo','senuelo','cambio','espejo']) k ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
  FOR i IN 1..30 LOOP
   u:=private.pick_inventory_recipient(rd,'antidoto');
   IF u=users[1] OR u=users[3] OR u=users[4] OR u IS NULL THEN RAISE EXCEPTION 'Rich or ineligible recipient selected';END IF;
  END LOOP;
  INSERT INTO private.debate_medicine_inventory(round_id,user_id,item,quantity) VALUES(rd,users[2],'antidoto',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
  mid:=gen_random_uuid();
  INSERT INTO private.debate_medicine_uses(id,round_id,cycle,sender,target,item) VALUES(mid,rd,4,users[5],users[2],'senuelo');
  PERFORM set_config('request.jwt.claim.sub',users[2]::text,true);
  denied:=false;BEGIN PERFORM private.defend_debate_medicine(rd,mid,'antidoto');EXCEPTION WHEN OTHERS THEN denied:=true;END;
  IF NOT denied OR (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=users[2] AND item='antidoto')<>1 THEN RAISE EXCEPTION 'Neutral consumed defence';END IF;
  UPDATE public.debate_vote_cycles SET choice='A' WHERE round_id=rd AND cycle_number=4 AND user_id=users[2];
  PERFORM private.defend_debate_medicine(rd,mid,'antidoto');
  IF (SELECT status FROM private.debate_medicine_uses WHERE id=mid)<>'blocked' THEN RAISE EXCEPTION 'Positioned defence failed';END IF;
  IF has_function_privilege('authenticated','private.pick_inventory_recipient(bigint,text)','EXECUTE') OR has_function_privilege('anon','public.draw_debate_proclamation(bigint)','EXECUTE') THEN RAISE EXCEPTION 'Unexpected client grant privilege';END IF;
  RAISE SQLSTATE 'ZX102' USING MESSAGE='R103 passed: 56 initial draws, 168 later cycles, idempotency, eligibility, nonhost save, strict majority, ties, resume, permissions';
 EXCEPTION WHEN SQLSTATE 'ZX102' THEN RAISE NOTICE '%',SQLERRM;
 END;
END $test$;
