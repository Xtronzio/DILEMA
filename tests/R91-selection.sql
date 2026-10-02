begin;
do $test$
declare rm bigint;solo bigint;manual bigint;pid bigint;replacement bigint;did bigint;rd bigint;x jsonb;n bigint;failed boolean;
u1 uuid:='00000000-0091-4000-8000-000000000001';u2 uuid:='00000000-0091-4000-8000-000000000002';u3 uuid:='00000000-0091-4000-8000-000000000003';outsider uuid:='00000000-0091-4000-8000-000000000004';
begin
 insert into auth.users(id,aud,role,email) values(u1,'authenticated','authenticated','r91-1@example.invalid'),(u2,'authenticated','authenticated','r91-2@example.invalid'),(u3,'authenticated','authenticated','r91-3@example.invalid'),(outsider,'authenticated','authenticated','r91-4@example.invalid');
 insert into public.rooms(code,host_id,expected_players,mode,status) values('T91R','r91-one',3,'debate','waiting') returning id into rm;
 insert into public.players(room_id,player_id,user_id,name) values(rm,'r91-one',u1,'ONE'),(rm,'r91-two',u2,'TWO'),(rm,'r91-three',u3,'THREE');
 perform set_config('request.jwt.claim.sub',u1::text,true);
 execute 'set local role authenticated';perform public.debate_begin_selection(rm);x:=public.debate_choose(rm,'3|ALEATORIO');execute 'reset role';
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';x:=public.debate_choose(rm,'3|ALEATORIO');execute 'reset role';
 if exists(select 1 from public.debate_dilemma_proposals where room_id=rm) then raise exception 'Random started before filter voting finished';end if;
 perform set_config('request.jwt.claim.sub',u3::text,true);execute 'set local role authenticated';x:=public.debate_choose(rm,'3|ALEATORIO');x:=public.debate_proposal_state(rm);execute 'reset role';
 pid:=(x->>'id')::bigint;did:=(x->>'dilemma_id')::bigint;
 if pid is null or x->>'status'<>'open' or x->>'has_voted'<>'false' then raise exception 'Last non-host filter voter did not automatically draw proposal';end if;
 -- Repeated reads and legacy host retries must not replace an open dilemma.
 execute 'set local role authenticated';x:=public.debate_proposal_state(rm);execute 'reset role';if (x->>'id')::bigint<>pid then raise exception 'Repeated read duplicated proposal';end if;
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';n:=public.debate_random_next(rm);execute 'reset role';if n<>pid then raise exception 'Legacy random action duplicated proposal';end if;
 -- Nobody accepts: last non-host ballot draws the replacement in the same transaction.
 execute 'set local role authenticated';perform public.debate_vote_proposal(pid,false);execute 'reset role';
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';perform public.debate_vote_proposal(pid,false);execute 'reset role';
 perform set_config('request.jwt.claim.sub',u3::text,true);execute 'set local role authenticated';perform public.debate_vote_proposal(pid,false);x:=public.debate_proposal_state(rm);execute 'reset role';
 replacement:=(x->>'id')::bigint;
 if replacement is null or replacement=pid or (x->>'dilemma_id')::bigint=did or (select status from public.rooms where id=rm)<>'waiting' then raise exception 'Rejection did not directly draw a different dilemma';end if;
 if x->>'has_voted'<>'false' or x->>'yes'<>'0' or x->>'no'<>'0' then raise exception 'Replacement retained old ballots';end if;
 -- The table accepts: majority opens A/B/N voting without the host start action.
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';perform public.debate_vote_proposal(replacement,true);execute 'reset role';
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';perform public.debate_vote_proposal(replacement,true);x:=public.debate_proposal_state(rm);execute 'reset role';
 select active_round_id into rd from public.rooms where id=rm;
 if rd is null or (select status from public.rounds where id=rd)<>'voting' or (select status from public.rooms where id=rm)<>'playing' or x<>'{}'::jsonb then raise exception 'Majority did not open posture voting';end if;
 if (select status from public.debate_dilemma_proposals where id=replacement)<>'launched' then raise exception 'Proposal not marked launched';end if;
 failed:=false;begin perform public.debate_vote_proposal(replacement,true);exception when others then failed:=SQLERRM='Votación cerrada';end;if not failed then raise exception 'Late vote not recognized as closed';end if;
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';n:=public.debate_start_approved(replacement);execute 'reset role';
 if n<>rd or (select count(*) from public.rounds where room_id=rm)<>1 then raise exception 'Legacy start duplicate round';end if;
 -- Host still starts the debate after reveal; other members cannot start it.
 update public.rounds set status='reveal' where id=rd;
 insert into public.votes(round_id,player_id,user_id,choice) values(rd,'r91-one',u1,'A'),(rd,'r91-two',u2,'B'),(rd,'r91-three',u3,'N');
 perform set_config('request.jwt.claim.sub',u2::text,true);failed:=false;begin execute 'set local role authenticated';x:=public.start_debate_engine(rd);exception when others then failed:=true;end;execute 'reset role';if not failed then raise exception 'Nonhost started debate';end if;
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';x:=public.start_debate_engine(rd);execute 'reset role';if (select status from public.rounds where id=rd)<>'debate' then raise exception 'Host cannot start debate';end if;
 -- Already waiting R90 selections are healed on the next member refresh.
 update public.rooms set status='waiting' where id=rm;
 update public.debate_selections set phase='random',last_round_id=rd,updated_at=clock_timestamp() where room_id=rm;
 perform set_config('request.jwt.claim.sub',u3::text,true);execute 'set local role authenticated';x:=public.debate_proposal_state(rm);execute 'reset role';if x->>'status'<>'open' then raise exception 'Old random waiting state not healed';end if;
 -- Catalogue exhaustion can recycle older rejections instead of stranding the table.
 update public.debate_dilemma_proposals set status='rejected' where room_id=rm and status='open';
 insert into public.debate_dilemma_proposals(room_id,dilemma_id,question,option_a,option_b,category,proposed_by,status)
 select rm,id,question,option_a,option_b,category,u1,'rejected' from public.dilemmas where source_kind='catalog' and audience='teen' and active and intensity<=3;
 execute 'set local role authenticated';x:=public.debate_proposal_state(rm);execute 'reset role';if x->>'status'<>'open' then raise exception 'Exhausted random catalog stranded table';end if;
 -- Personalized proposals still require consent and carry their context into voting.
 insert into public.rooms(code,host_id,expected_players,mode,status) values('T91M','r91-one',3,'debate','waiting') returning id into manual;
 insert into public.players(room_id,player_id,user_id,name) values(manual,'r91-one',u1,'ONE'),(manual,'r91-two',u2,'TWO'),(manual,'r91-three',u3,'THREE');
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';pid:=public.debate_propose_with_context(manual,'CUSTOM QUESTION','A','B','KEEP CONTEXT');execute 'reset role';
 if (select status from public.rooms where id=manual)<>'waiting' then raise exception 'Manual skipped table consent';end if;
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';perform public.debate_vote_proposal(pid,true);execute 'reset role';
 if (select context from public.rounds where id=(select active_round_id from public.rooms where id=manual))<>'KEEP CONTEXT' then raise exception 'Manual context lost';end if;
 insert into public.rooms(code,host_id,expected_players,mode,status) values('T91S','r91-one',1,'debate','waiting') returning id into solo;
 insert into public.players(room_id,player_id,user_id,name) values(solo,'r91-one',u1,'ONE');
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';pid:=public.debate_propose_with_context(solo,'SOLO QUESTION','A','B','SOLO CONTEXT');execute 'reset role';
 if (select context from public.rounds where id=(select active_round_id from public.rooms where id=solo))<>'SOLO CONTEXT' then raise exception 'Solo automatic acceptance lost context';end if;
 -- Outsiders and direct private calls cannot draw or launch dilemmas.
 perform set_config('request.jwt.claim.sub',outsider::text,true);failed:=false;begin execute 'set local role authenticated';x:=public.debate_proposal_state(rm);exception when others then failed:=true;end;execute 'reset role';if not failed then raise exception 'Outsider allowed';end if;
 perform set_config('request.jwt.claim.sub',u1::text,true);failed:=false;begin execute 'set local role authenticated';perform private.random_dilemma(rm);exception when insufficient_privilege then failed:=true;end;execute 'reset role';if not failed then raise exception 'Private random publicly executable';end if;
 failed:=false;begin execute 'set local role authenticated';perform private.launch_approved_dilemma(pid);exception when insufficient_privilege then failed:=true;end;execute 'reset role';if not failed then raise exception 'Private launch publicly executable';end if;
 raise notice 'R91 automatic draw, rejection replacement, automatic posture voting, host start, recovery, recycling, context and permissions passed';
end $test$;
rollback;
