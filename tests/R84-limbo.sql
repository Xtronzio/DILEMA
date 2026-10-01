begin;
do $test$
declare room bigint;rd bigint;d bigint;proposal bigint;x jsonb;failed boolean;
 u1 uuid:='00000000-0084-4000-8000-000000000001';u2 uuid:='00000000-0084-4000-8000-000000000002';u3 uuid:='00000000-0084-4000-8000-000000000003';u4 uuid:='00000000-0084-4000-8000-000000000004';outsider uuid:='00000000-0084-4000-8000-000000000005';
begin
 insert into auth.users(id,aud,role,email) values(u1,'authenticated','authenticated','r84-1@example.invalid'),(u2,'authenticated','authenticated','r84-2@example.invalid'),(u3,'authenticated','authenticated','r84-3@example.invalid'),(u4,'authenticated','authenticated','r84-4@example.invalid'),(outsider,'authenticated','authenticated','r84-5@example.invalid');
 perform set_config('request.jwt.claim.sub',u1::text,true);
 insert into public.rooms(code,host_id,expected_players,mode,status) values('T84Q','r84-host',4,'debate','playing') returning id into room;
 insert into public.players(room_id,player_id,user_id,name) values(room,'r84-host',u1,'HOST'),(room,'r84-two',u2,'TWO'),(room,'r84-three',u3,'THREE'),(room,'r84-four',u4,'FOUR');
 select min(id) into d from public.dilemmas;
 insert into public.rounds(room_id,dilemma_id,debate_phase,status) values(room,d,'debate','debate') returning id into rd;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) values(rd,1,'r84-host',u1,'A'),(rd,1,'r84-two',u2,'B'),(rd,1,'r84-three',u3,'B'),(rd,1,'r84-four',u4,'A');
 -- The target cannot vote. Three eligible members, with the proposer already YES.
 execute 'set local role authenticated';x:=public.propose_debate_limbo(rd,'r84-two',180);execute 'reset role';proposal:=(x->>'id')::bigint;
 perform set_config('request.jwt.claim.sub',u2::text,true);x:=private.limbo_state(rd);
 if x->'proposal'->>'players'<>'3' or x->'proposal'->>'yes'<>'1' or x->'proposal'->>'target_me'<>'true' or x->'proposal'->>'can_vote'<>'false' then raise exception 'Target ballot or denominator incorrect';end if;
 failed:=false;begin execute 'set local role authenticated';perform public.cast_debate_limbo_vote(rd,proposal,'YES');exception when others then failed:=true;end;execute 'reset role';
 if not failed or exists(select 1 from private.debate_limbo_votes where proposal_id=proposal and user_id=u2) then raise exception 'Target voted own limbo';end if;
 perform set_config('request.jwt.claim.sub',outsider::text,true);failed:=false;begin perform public.cast_debate_limbo_vote(rd,proposal,'YES');exception when others then failed:=true;end;
 if not failed then raise exception 'Outsider votes';end if;
 perform set_config('request.jwt.claim.sub',u3::text,true);execute 'set local role authenticated';x:=public.cast_debate_limbo_vote(rd,proposal,'YES');execute 'reset role';
 if x->>'status'<>'accepted' or not exists(select 1 from public.players where room_id=room and user_id=u2 and presence='absent') then raise exception '2 of 3 eligible did not accept';end if;
 perform set_config('request.jwt.claim.sub',u4::text,true);x:=public.cast_debate_limbo_vote(rd,proposal,'NO');if x->>'status'<>'closed' then raise exception 'Late vote not closed';end if;
 perform set_config('request.jwt.claim.sub',u2::text,true);x:=private.limbo_state(rd);if x->>'blocked'<>'true' then raise exception 'Limbo return not blocked';end if;
 failed:=false;begin perform public.propose_presence_change(rd,'return',null);exception when others then failed:=true;end;if not failed then raise exception 'Return during countdown';end if;
 -- With three present, a split between the other two rejects. Old target votes do not count.
 perform set_config('request.jwt.claim.sub',u1::text,true);x:=public.propose_debate_limbo(rd,'r84-three',300);proposal:=(x->>'id')::bigint;
 insert into private.debate_limbo_votes values(proposal,u3,'YES');
 x:=private.limbo_state(rd);if x->'proposal'->>'yes'<>'1' or x->'proposal'->>'players'<>'2' then raise exception 'Legacy target vote counted';end if;
 perform set_config('request.jwt.claim.sub',u4::text,true);x:=public.cast_debate_limbo_vote(rd,proposal,'NO');if x->>'status'<>'rejected' then raise exception 'Tie not rejected';end if;
 -- A host may be the target; acceptance transfers the organizer role.
 x:=public.propose_debate_limbo(rd,'r84-host',0);proposal:=(x->>'id')::bigint;
 perform set_config('request.jwt.claim.sub',u3::text,true);x:=public.cast_debate_limbo_vote(rd,proposal,'YES');
 if x->>'status'<>'accepted' or (select host_id from public.rooms where id=room)='r84-host' then raise exception 'Host limbo transfer failed';end if;
 x:=private.limbo_state(rd);if x->>'can_propose'<>'false' then raise exception 'Limbo available with two present';end if;
 failed:=false;begin perform public.propose_debate_limbo(rd,'r84-four',180);exception when others then failed:=true;end;if not failed then raise exception 'Limbo proposed with two';end if;
 -- Expiry allows a request again, but does not return the player automatically.
 update private.debate_limbo_proposals set until_at=clock_timestamp()-interval '1 second' where round_id=rd and target_user_id=u2;
 perform set_config('request.jwt.claim.sub',u2::text,true);x:=private.limbo_state(rd);if x->>'blocked'<>'false' then raise exception 'Expired lock persists';end if;
 if (select presence from public.players where room_id=room and user_id=u2)<>'absent' then raise exception 'Automatic return';end if;
 raise notice 'R84 limbo target exclusion, denominator, majority, tie, two-player guard, host transfer, countdown and late votes passed';
end $test$;
rollback;
