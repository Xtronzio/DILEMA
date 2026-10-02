BEGIN;
DO $test$
DECLARE ids uuid[]:=ARRAY['00000000-0094-4000-8000-000000000001','00000000-0094-4000-8000-000000000002','00000000-0094-4000-8000-000000000003','00000000-0094-4000-8000-000000000004','00000000-0094-4000-8000-000000000005','00000000-0094-4000-8000-000000000006']::uuid[];
rm bigint;pid bigint;original bigint;replacement bigint;i integer;j integer;cycle integer;x jsonb;failed boolean;seen_accept boolean:=false;seen_reject boolean:=false;sample bigint[];d bigint;
BEGIN
 FOR i IN 1..6 LOOP INSERT INTO auth.users(id,aud,role,email) VALUES(ids[i],'authenticated','authenticated','r94-'||i||'@example.invalid');END LOOP;
 -- A majority of NO closes the proposal before the remaining two vote.
 INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('T941','r94-1',5,'debate','waiting') RETURNING id INTO rm;
 FOR i IN 1..5 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r94-'||i,ids[i],'PLAYER '||i);END LOOP;
 INSERT INTO public.debate_selections(room_id,phase,intensity,theme,last_round_id) VALUES(rm,'random',3,'ALEATORIO',0);
 PERFORM set_config('request.jwt.claim.sub',ids[1]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.debate_proposal_state(rm);EXECUTE 'RESET ROLE';pid:=(x->>'id')::bigint;original:=pid;
 FOR i IN 1..2 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,false,1);EXECUTE 'RESET ROLE';END LOOP;
 IF (SELECT status FROM public.debate_dilemma_proposals WHERE id=pid)<>'open' THEN RAISE EXCEPTION 'Minority discarded proposal';END IF;
 PERFORM set_config('request.jwt.claim.sub',ids[3]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,false,1);x:=public.debate_proposal_state(rm);EXECUTE 'RESET ROLE';replacement:=(x->>'id')::bigint;
 IF (SELECT status FROM public.debate_dilemma_proposals WHERE id=pid)<>'rejected' OR replacement IS NULL OR replacement=pid OR (SELECT count(*) FROM public.debate_dilemma_proposal_votes WHERE proposal_id=pid)<>3 THEN RAISE EXCEPTION '3/5 did not discard immediately';END IF;
 IF (SELECT resolved_by FROM public.debate_dilemma_proposals WHERE id=pid)<>'majority' OR x->>'yes'<>'0' OR x->>'no'<>'0' THEN RAISE EXCEPTION 'Replacement retained old votes';END IF;
 PERFORM set_config('request.jwt.claim.sub',ids[4]::text,true);failed:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,true,1);EXCEPTION WHEN OTHERS THEN failed:=SQLERRM='Votación cerrada';END;EXECUTE 'RESET ROLE';IF NOT failed THEN RAISE EXCEPTION 'Late discard ballot not rejected';END IF;
 -- A majority of YES has the identical threshold and opens posture voting.
 FOR i IN 1..3 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(replacement,true,1);EXECUTE 'RESET ROLE';END LOOP;
 IF (SELECT status FROM public.rooms WHERE id=rm)<>'playing' OR (SELECT resolved_by FROM public.debate_dilemma_proposals WHERE id=replacement)<>'majority' THEN RAISE EXCEPTION '3/5 did not accept immediately';END IF;
 -- Even tables: first tie clears only the current-cycle view, preserves the ballots.
 FOR j IN 2..9 LOOP
  INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('T94'||j,'r94-1',4,'debate','waiting') RETURNING id INTO rm;
  FOR i IN 1..4 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r94-'||i,ids[i],'PLAYER '||i);END LOOP;
  INSERT INTO public.debate_dilemma_proposals(room_id,question,option_a,option_b,proposed_by) VALUES(rm,'TIED QUESTION','A','B',ids[1]) RETURNING id INTO pid;
  FOR i IN 1..4 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,i<=2,1);EXECUTE 'RESET ROLE';END LOOP;
  EXECUTE 'SET LOCAL ROLE authenticated';x:=public.debate_proposal_state(rm);EXECUTE 'RESET ROLE';
  IF x->>'vote_cycle'<>'2' OR x->>'yes'<>'0' OR x->>'no'<>'0' OR x->>'has_voted'<>'false' OR (SELECT count(*) FROM public.debate_dilemma_proposal_votes WHERE proposal_id=pid AND vote_cycle=1)<>4 THEN RAISE EXCEPTION 'First tie lost history or did not offer second vote';END IF;
  failed:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,false,1);EXCEPTION WHEN OTHERS THEN failed:=SQLERRM LIKE '%ha empatado%';END;EXECUTE 'RESET ROLE';IF NOT failed THEN RAISE EXCEPTION 'Stale first-cycle vote leaked into runoff';END IF;
  IF j=2 THEN
   -- A majority in the second round wins normally; first-round votes do not count.
   FOR i IN 1..3 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,false,2);EXECUTE 'RESET ROLE';END LOOP;
   IF (SELECT status FROM public.debate_dilemma_proposals WHERE id=pid)<>'rejected' OR (SELECT resolved_by FROM public.debate_dilemma_proposals WHERE id=pid)<>'majority' THEN RAISE EXCEPTION 'Second cycle majority not applied';END IF;
  ELSE
   PERFORM setseed((j-5)::double precision/5);
   FOR i IN 1..4 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,i<=2,2);EXECUTE 'RESET ROLE';END LOOP;
   IF (SELECT resolved_by FROM public.debate_dilemma_proposals WHERE id=pid)<>'draw' OR (SELECT status FROM public.debate_dilemma_proposals WHERE id=pid) NOT IN('launched','rejected') THEN RAISE EXCEPTION 'Second tie failed to resolve by draw';END IF;
   seen_accept:=seen_accept OR (SELECT status='launched' FROM public.debate_dilemma_proposals WHERE id=pid);seen_reject:=seen_reject OR (SELECT status='rejected' FROM public.debate_dilemma_proposals WHERE id=pid);
  END IF;
 END LOOP;
 IF NOT seen_accept OR NOT seen_reject THEN RAISE EXCEPTION 'Draw acceptance and rejection paths not both exercised';END IF;
 -- Absent members do not count; outsiders and unsigned users cannot vote.
 INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('T94A','r94-1',5,'debate','waiting') RETURNING id INTO rm;
 FOR i IN 1..5 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r94-'||i,ids[i],'PLAYER '||i);END LOOP;
 UPDATE public.players SET presence='absent' WHERE room_id=rm AND user_id=ids[5];
 INSERT INTO public.debate_dilemma_proposals(room_id,question,option_a,option_b,proposed_by) VALUES(rm,'PRESENT ONLY','A','B',ids[1]) RETURNING id INTO pid;
 PERFORM set_config('request.jwt.claim.sub',ids[6]::text,true);failed:=false;BEGIN EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal_cycle(pid,false,1);EXCEPTION WHEN OTHERS THEN failed:=true;END;EXECUTE 'RESET ROLE';IF NOT failed THEN RAISE EXCEPTION 'Outsider voted';END IF;
 failed:=false;BEGIN EXECUTE 'SET LOCAL ROLE anon';PERFORM public.debate_vote_proposal_cycle(pid,false,1);EXCEPTION WHEN insufficient_privilege THEN failed:=true;END;EXECUTE 'RESET ROLE';IF NOT failed THEN RAISE EXCEPTION 'Anonymous RPC permitted';END IF;
 FOR i IN 1..3 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';PERFORM public.debate_vote_proposal(pid,false);EXECUTE 'RESET ROLE';END LOOP;
 IF (SELECT status FROM public.debate_dilemma_proposals WHERE id=pid)<>'rejected' THEN RAISE EXCEPTION 'Legacy clients cannot cast with absent member';END IF;
 -- World candidates use the same early majority for discarding the complete batch.
 SELECT array_agg(id) INTO sample FROM (SELECT id FROM public.dilemmas WHERE active AND source_kind='catalog' AND audience='teen' LIMIT 3)t;
 INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('T94B','r94-1',5,'debate','waiting') RETURNING id INTO rm;
 FOR i IN 1..5 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r94-'||i,ids[i],'PLAYER '||i);END LOOP;
 INSERT INTO public.debate_selections(room_id,phase,intensity,theme,options,last_round_id) VALUES(rm,'questions',3,'ACTUALIDAD IA:ALEATORIO',to_jsonb(sample),0);
 FOR i IN 1..3 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.debate_choose(rm,'__DISCARD__');EXECUTE 'RESET ROLE';IF i<3 AND x->>'phase'<>'questions' THEN RAISE EXCEPTION 'World candidates discarded by minority';END IF;END LOOP;
 IF x->>'phase'<>'news_loading' OR (SELECT count(*) FROM public.debate_selection_votes WHERE room_id=rm)<>3 THEN RAISE EXCEPTION 'World discard still waits for everyone';END IF;
 -- Merely winning the plurality 2/5 cannot discard a batch: force a binary runoff.
 INSERT INTO public.rooms(code,host_id,expected_players,mode,status) VALUES('T94C','r94-1',5,'debate','waiting') RETURNING id INTO rm;
 FOR i IN 1..5 LOOP INSERT INTO public.players(room_id,player_id,user_id,name) VALUES(rm,'r94-'||i,ids[i],'PLAYER '||i);END LOOP;
 INSERT INTO public.debate_selections(room_id,phase,intensity,theme,options,last_round_id) VALUES(rm,'questions',3,'ACTUALIDAD IA:ALEATORIO',to_jsonb(sample),0);
 FOR i IN 1..5 LOOP PERFORM set_config('request.jwt.claim.sub',ids[i]::text,true);EXECUTE 'SET LOCAL ROLE authenticated';x:=public.debate_choose(rm,CASE WHEN i<=2 THEN '__DISCARD__' ELSE sample[i-2]::text END);EXECUTE 'RESET ROLE';END LOOP;
 IF x->>'phase'<>'runoff' OR NOT(x->'options' ? '__DISCARD__') THEN RAISE EXCEPTION 'World plurality improperly discarded batch';END IF;
 RAISE NOTICE 'R94: majority acceptance/discard, immediate replacement, late votes, runoff, draw, preserved ballots, presence, permissions, old clients and world discard passed';
END $test$;
ROLLBACK;
