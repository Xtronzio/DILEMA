BEGIN;
DO $test$
DECLARE ids uuid[]:=ARRAY['00000000-0095-4000-8000-000000000001','00000000-0095-4000-8000-000000000002','00000000-0095-4000-8000-000000000003','00000000-0095-4000-8000-000000000004','00000000-0095-4000-8000-000000000005']::uuid[];
 rm bigint;rd bigint;d bigint;i integer;x jsonb;ticket uuid;sid uuid;bad boolean;old text;drawn bigint;
BEGIN
 FOR i IN 1..5 LOOP INSERT INTO auth.users(id,aud,role,email) VALUES(ids[i],'authenticated','authenticated','r95-'||i||'@example.invalid');END LOOP;
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);
 EXECUTE 'SET LOCAL ROLE authenticated';
 INSERT INTO public.private_dilemma_sessions(question) VALUES('No sé qué quiero hacer este verano.') RETURNING id INTO sid;
 x:=public.prepare_private_dialogue(sid,sid,'Quiero explorar este dilema. Ayúdame a empezar.');
 IF x->'context'->>'option_a'<>'' OR x->'context'->>'audience'<>'teen' THEN RAISE EXCEPTION 'Question-only conversation lost audience';END IF;
 bad:=false;BEGIN INSERT INTO public.private_dilemma_sessions(question,option_a) VALUES('Incomplete','Only A');EXCEPTION WHEN check_violation THEN bad:=true;END;
 IF NOT bad THEN RAISE EXCEPTION 'Half-defined options accepted';END IF;
 bad:=false;BEGIN UPDATE public.private_dilemma_sessions SET choice='A' WHERE id=sid;EXCEPTION WHEN check_violation THEN bad:=true;END;
 IF NOT bad THEN RAISE EXCEPTION 'Voted on nonexistent options';END IF;
 EXECUTE 'RESET ROLE';
 SELECT id INTO d FROM public.dilemmas WHERE active AND source_kind='catalog' LIMIT 1;
 INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('R95T','r95-1',4,'debate','playing') RETURNING id INTO rm;
 FOR i IN 1..4 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r95-'||i,ids[i],'PLAYER '||i);END LOOP;
 INSERT INTO public.rounds(room_id,dilemma_id,status,debate_phase) VALUES(rm,d,'voting','initial_vote') RETURNING id INTO rd;
 FOR i IN 1..4 LOOP INSERT INTO public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) VALUES(rd,1,'r95-'||i,ids[i],CASE WHEN i=3 THEN 'B' WHEN i=4 THEN 'N' ELSE 'A' END);END LOOP;
 UPDATE public.rounds SET status='debate',debate_phase='debate' WHERE id=rd;
 IF (SELECT count(*) FROM private.debate_medicine_draws WHERE round_id=rd)<>6 OR (SELECT sum(quantity) FROM private.debate_medicine_inventory WHERE round_id=rd)<>6 OR EXISTS(SELECT 1 FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[4]) THEN RAISE EXCEPTION 'Initial lottery failed or neutral received tools';END IF;
 -- Deterministic resources for effect tests; draw ledger prevents accidental rerolls.
 UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=rd;
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[1],'cambio',1),(rd,ids[2],'antidoto',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'cambio','r95-2',ticket);EXECUTE 'RESET ROLE';
 IF NOT(x->>'busy')::boolean OR (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[1] AND item='cambio')<>0 THEN RAISE EXCEPTION 'Launch did not reserve resource';END IF;
 EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'cambio','r95-2',ticket);EXECUTE 'RESET ROLE';
 IF (SELECT count(*) FROM private.debate_medicine_uses WHERE id=ticket)<>1 THEN RAISE EXCEPTION 'Idempotent launch duplicated';END IF;
 bad:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.propose_debate_twist_vote(rd);EXCEPTION WHEN OTHERS THEN bad:=SQLERRM LIKE '%Another proposal%';END;EXECUTE 'RESET ROLE';IF NOT bad THEN RAISE EXCEPTION 'Giro allowed during defence';END IF;
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.get_debate_state(rd);EXECUTE 'RESET ROLE';
 IF x->'medicine_state'->'pending'->>'item' IS NOT NULL OR NOT(x->'medicine_state'->'pending'->>'incoming')::boolean THEN RAISE EXCEPTION 'Incoming potion revealed before defence';END IF;
 EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'antidoto');EXECUTE 'RESET ROLE';
 IF (SELECT choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1 AND user_id=ids[2])<>'A' OR (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[2] AND item='antidoto')<>0 THEN RAISE EXCEPTION 'Antidote failed';END IF;
 EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'antidoto');EXECUTE 'RESET ROLE';
 -- Undefended flip and preservation of the recipient's personal change token.
 INSERT INTO public.debate_secret_revotes(round_id,player_id,user_id,grant_cycle) VALUES(rd,'r95-2',ids[2],1);
 UPDATE private.debate_medicine_inventory SET quantity=1 WHERE round_id=rd AND user_id=ids[1] AND item='cambio';
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'cambio','r95-2',ticket);EXECUTE 'RESET ROLE';
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'none');EXECUTE 'RESET ROLE';
 IF (SELECT choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1 AND user_id=ids[2])<>'B' OR NOT EXISTS(SELECT 1 FROM public.debate_secret_revotes WHERE round_id=rd AND user_id=ids[2] AND used_at IS NULL) THEN RAISE EXCEPTION 'Flip spent personal change';END IF;
 -- Mirror consumes a pill and changes the sender, not the recipient.
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[2],'espejo',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 UPDATE private.debate_medicine_inventory SET quantity=1 WHERE round_id=rd AND user_id=ids[1] AND item='cambio';
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'cambio','r95-2',ticket);EXECUTE 'RESET ROLE';
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'espejo');EXECUTE 'RESET ROLE';
 IF (SELECT choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1 AND user_id=ids[1])<>'B' OR (SELECT status FROM private.debate_medicine_uses WHERE id=ticket)<>'reflected' THEN RAISE EXCEPTION 'Mirror failed';END IF;
 -- Bait spends a defence but never changes votes.
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[1],'senuelo',1),(rd,ids[2],'antidoto',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'senuelo','r95-2',ticket);EXECUTE 'RESET ROLE';
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'antidoto');EXECUTE 'RESET ROLE';
 IF (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[2] AND item='antidoto')<>0 OR x->'event'->>'result' NOT LIKE '%señuelo%' THEN RAISE EXCEPTION 'Bait failed';END IF;
 -- Theft transfers an actual item, respecting the one-per-type cap.
 UPDATE private.debate_medicine_inventory SET quantity=0 WHERE round_id=rd;
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[1],'robo',1),(rd,ids[2],'antidoto',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'robo','r95-2',ticket);EXECUTE 'RESET ROLE';
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'none');EXECUTE 'RESET ROLE';
 IF (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[1] AND item='antidoto')<>1 OR (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[2] AND item='antidoto')<>0 THEN RAISE EXCEPTION 'Theft failed';END IF;
 -- Timeout acts without a client countdown deciding the result.
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[1],'cambio',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'cambio','r95-2',ticket);EXECUTE 'RESET ROLE';
 UPDATE private.debate_medicine_uses SET deadline=clock_timestamp()-interval '1 second' WHERE id=ticket;
 PERFORM set_config('request.jwt.claim.sub',ids[3]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.get_debate_state(rd);EXECUTE 'RESET ROLE';
 IF (SELECT status FROM private.debate_medicine_uses WHERE id=ticket)<>'applied' OR (SELECT choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1 AND user_id=ids[2])<>'A' THEN RAISE EXCEPTION 'Server timeout failed';END IF;
 -- Neutral and outsiders cannot launch or read the medicine state.
 PERFORM set_config('request.jwt.claim.sub',ids[4]::text,true);bad:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.launch_debate_medicine(rd,'robo','r95-1',gen_random_uuid());EXCEPTION WHEN OTHERS THEN bad:=true;END;EXECUTE 'RESET ROLE';IF NOT bad THEN RAISE EXCEPTION 'Neutral used tools';END IF;
 PERFORM set_config('request.jwt.claim.sub',ids[5]::text,true);bad:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.get_debate_state(rd);EXCEPTION WHEN OTHERS THEN bad:=true;END;EXECUTE 'RESET ROLE';IF NOT bad THEN RAISE EXCEPTION 'Outsider saw state';END IF;
 bad:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM private.draw_medicines(rd);EXCEPTION WHEN insufficient_privilege THEN bad:=true;END;EXECUTE 'RESET ROLE';IF NOT bad THEN RAISE EXCEPTION 'Client can force lottery';END IF;
 -- Exactly one lottery per cycle, even after items are consumed; resuming does not redraw.
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);drawn:=(SELECT count(*) FROM private.debate_medicine_draws WHERE round_id=rd);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.get_debate_state(rd);x:=public.get_debate_state(rd);EXECUTE 'RESET ROLE';IF (SELECT count(*) FROM private.debate_medicine_draws WHERE round_id=rd)<>drawn THEN RAISE EXCEPTION 'Repeated state redrew';END IF;
 INSERT INTO public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) SELECT round_id,2,player_id,user_id,choice FROM public.debate_vote_cycles WHERE round_id=rd AND cycle_number=1;
 UPDATE public.rounds SET vote_cycle=2 WHERE id=rd;
 IF (SELECT count(*) FROM private.debate_medicine_draws WHERE round_id=rd)<>12 OR EXISTS(SELECT 1 FROM private.debate_medicine_inventory WHERE quantity>1) THEN RAISE EXCEPTION 'Cycle recharge failed';END IF;
 -- Limbo is timed, blocks return and changes host when its recipient was hosting.
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[2],'limbo',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);ticket:=gen_random_uuid();EXECUTE 'SET LOCAL ROLE authenticated';x:=public.launch_debate_medicine(rd,'limbo','r95-1',ticket);EXECUTE 'RESET ROLE';
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.defend_debate_medicine(rd,ticket,'none');EXECUTE 'RESET ROLE';
 IF (SELECT presence FROM public.players WHERE room_id=rm AND user_id=ids[1])<>'absent' OR NOT private.limbo_blocked(rm,ids[1]) OR (SELECT host_id FROM public.rooms WHERE id=rm)='r95-1' THEN RAISE EXCEPTION 'Limbo/host handoff failed';END IF;
 UPDATE public.players SET presence='absent' WHERE room_id=rm AND user_id=ids[4];
 INSERT INTO private.debate_medicine_inventory VALUES(rd,ids[2],'limbo',1) ON CONFLICT(round_id,user_id,item) DO UPDATE SET quantity=1;
 PERFORM set_config('request.jwt.claim.sub',ids[2]::text,true);bad:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.launch_debate_medicine(rd,'limbo','r95-3',gen_random_uuid());EXCEPTION WHEN OTHERS THEN bad:=true;END;EXECUTE 'RESET ROLE';IF NOT bad OR (SELECT quantity FROM private.debate_medicine_inventory WHERE round_id=rd AND user_id=ids[2] AND item='limbo')<>1 THEN RAISE EXCEPTION 'Two-player limbo allowed or consumed';END IF;
 RAISE NOTICE 'R95: optional private options, audience, lottery/cap/recharge, effects, defences, bait, theft, timeout, idempotency, serialization, neutral, permissions and limbo passed';
END $test$;
ROLLBACK;
