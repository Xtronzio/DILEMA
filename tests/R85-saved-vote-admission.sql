begin;
do $test$
declare room bigint;rd bigint;rd2 bigint;d bigint;request bigint;saved uuid;x jsonb;failed boolean;n bigint;
 u1 uuid:='00000000-0085-4000-8000-000000000001';u2 uuid:='00000000-0085-4000-8000-000000000002';u3 uuid:='00000000-0085-4000-8000-000000000003';u4 uuid:='00000000-0085-4000-8000-000000000004';
begin
 insert into auth.users(id,aud,role,email) values(u1,'authenticated','authenticated','r85-1@example.invalid'),(u2,'authenticated','authenticated','r85-2@example.invalid'),(u3,'authenticated','authenticated','r85-3@example.invalid'),(u4,'authenticated','authenticated','r85-4@example.invalid');
 perform set_config('request.jwt.claim.sub',u1::text,true);
 insert into public.rooms(code,host_id,expected_players,mode,status) values('T85Q','r85-host',3,'debate','playing') returning id into room;
 insert into public.players(room_id,player_id,user_id,name) values(room,'r85-host',u1,'HOST'),(room,'r85-two',u2,'TWO'),(room,'r85-three',u3,'THREE');
 select min(id) into d from public.dilemmas;
 insert into public.rounds(room_id,dilemma_id,debate_phase,status) values(room,d,'debate','debate') returning id into rd;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) values(rd,1,'r85-host',u1,'A'),(rd,1,'r85-two',u2,'B'),(rd,1,'r85-three',u3,'B');
 perform public.set_debate_admission(room,true);
 perform set_config('request.jwt.claim.sub',u4::text,true);request:=public.request_debate_admission(room,'r85-new','NEW','⭐','');
 x:=public.my_debate_admission(request);if x->>'status'<>'open' or x?'dilemma' or x?'state' then raise exception 'Unapproved applicant gets debate payload';end if;
 perform set_config('request.jwt.claim.sub',u1::text,true);failed:=false;begin perform public.my_debate_admission(request);exception when others then failed:=true;end;if not failed then raise exception 'Another user reads application';end if;
 perform public.vote_debate_admission(rd,request,true);perform set_config('request.jwt.claim.sub',u2::text,true);perform public.vote_debate_admission(rd,request,true);
 perform set_config('request.jwt.claim.sub',u4::text,true);execute 'set local role authenticated';x:=public.my_debate_admission(request);execute 'reset role';
 if x->>'status'<>'accepted' or x->'room'->>'id'<>room::text or x->'round'->>'id'<>rd::text or x->'dilemma'->>'id'<>d::text or x->'state'->'admission_state'->>'needs_vote'<>'true' or x->'state'->'admission_state'->>'can_vote'<>'true' then raise exception 'Accepted response does not contain first-vote board';end if;
 if x->'state'->>'votes_a'<>'1' or x->'state'->>'votes_b'<>'2' then raise exception 'Existing votes altered';end if;
 if x->'state'?'votes' or x->'state'?'player_choices' then raise exception 'Individual votes exposed';end if;
 perform public.debate_admission_initial_vote(rd,'B');x:=public.my_debate_admission(request);
 if x->'state'->'admission_state'->>'needs_vote'<>'false' or x->'state'->'admission_state'->>'waiting_votes'<>'0' then raise exception 'Admission locks not cleared';end if;
 -- Preserve the host's actual last choice, including later cycles, without changing peers' history.
 update public.rounds set vote_cycle=2 where id=rd;
 insert into public.debate_vote_cycles(round_id,cycle_number,player_id,user_id,choice) values(rd,2,'r85-host',u1,'B'),(rd,2,'r85-two',u2,'A');
 perform set_config('request.jwt.claim.sub',u1::text,true);update public.rounds set debate_phase='finished' where id=rd;
 select id into saved from public.saved_group_dilemmas where source_round_id=rd and user_id=u1;
 if saved is null or (select choice from public.saved_group_dilemmas where id=saved)<>'B' then raise exception 'Latest host vote not archived';end if;
 execute 'set local role authenticated';select count(*) into n from public.saved_group_dilemmas where id=saved;execute 'reset role';if n<>1 then raise exception 'Owner cannot read last vote';end if;
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';select count(*) into n from public.saved_group_dilemmas where id=saved;execute 'reset role';if n<>0 then raise exception 'Private history exposed';end if;
 -- No recorded vote remains explicitly unknown, rather than choosing A by default.
 insert into public.rounds(room_id,dilemma_id,debate_phase,status) values(room,d,'debate','debate') returning id into rd2;
 update public.rounds set debate_phase='finished' where id=rd2;
 if not exists(select 1 from public.saved_group_dilemmas where source_round_id=rd2 and choice is null) then raise exception 'Missing choice invented';end if;
 raise notice 'R85 accepted handoff payload, authorization, first vote, archived last choice and privacy passed';
end $test$;
rollback;
