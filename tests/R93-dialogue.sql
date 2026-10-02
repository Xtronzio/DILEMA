begin;
do $test$
declare u1 uuid:='00000000-0093-4000-8000-000000000001';u2 uuid:='00000000-0093-4000-8000-000000000002';s1 uuid;s2 uuid;req uuid:=gen_random_uuid();next_req uuid:=gen_random_uuid();other_req uuid:=gen_random_uuid();x jsonb;lease uuid;failed boolean;n integer;
begin
 insert into auth.users(id,aud,role,email) values(u1,'authenticated','authenticated','r93-1@example.invalid'),(u2,'authenticated','authenticated','r93-2@example.invalid');
 perform set_config('request.jwt.claim.sub',u1::text,true);
 insert into public.private_dilemma_sessions(question,option_a,option_b,choice,user_id,context) values('PRIVATE QUESTION','OPTION A','OPTION B','N',u1,'CONTEXT ONE') returning id into s1;
 perform set_config('request.jwt.claim.sub',u2::text,true);
 insert into public.private_dilemma_sessions(question,option_a,option_b,choice,user_id) values('OTHER PRIVATE QUESTION','OTHER A','OTHER B','A',u2) returning id into s2;
 perform set_config('request.jwt.claim.sub',u1::text,true);
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,req,'I AM IN DOUBT');execute 'reset role';
 lease:=(x->>'lease_id')::uuid;
 if x->>'status'<>'prepared' or x->'context'->>'choice'<>'N' or x->'context'->>'context'<>'CONTEXT ONE' then raise exception 'Neutral dialogue prepare failed';end if;
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,req,'I AM IN DOUBT');execute 'reset role';if x->>'status'<>'pending' then raise exception 'Duplicate request generated twice';end if;
 failed:=false;begin execute 'set local role authenticated';perform public.prepare_private_dialogue(s1,other_req,'CONCURRENT MESSAGE');exception when others then failed:=SQLERRM='DIALOGUE_BUSY';end;execute 'reset role';if not failed then raise exception 'Concurrent provider calls allowed';end if;
 failed:=false;begin execute 'set local role authenticated';perform public.finish_private_dialogue(req,lease,u1,'FORGED REPLY','FORGED QUESTION','FORGED MEMORY','IA');exception when insufficient_privilege then failed:=true;end;execute 'reset role';if not failed then raise exception 'User could forge AI reply';end if;
 failed:=false;begin execute 'set local role authenticated';update public.private_dilemma_dialogue_turns set reflection='FORGED' where id=req;exception when insufficient_privilege then failed:=true;end;execute 'reset role';if not failed then raise exception 'User direct update allowed';end if;
 execute 'set local role service_role';x:=public.finish_private_dialogue(req,gen_random_uuid(),u1,'REPLY','QUESTION?','MEMORY','IA');execute 'reset role';if x->>'status'<>'superseded' then raise exception 'Wrong lease saved';end if;
 execute 'set local role service_role';x:=public.finish_private_dialogue(req,lease,u1,'REPLY','QUESTION?','FIRST MEMORY','IA','{"model":"TEST","input_tokens":120,"cached_input_tokens":30,"output_tokens":40}'::jsonb);execute 'reset role';if x->>'status'<>'ready' then raise exception 'Server completion failed';end if;
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,req,'I AM IN DOUBT');execute 'reset role';if x->>'status'<>'ready' or x->'turn'->>'reflection'<>'REPLY' then raise exception 'Cached retry lost reply';end if;
 if (select count(*) from public.private_dilemma_dialogue_turns where session_id=s1)<>1 then raise exception 'Duplicate dialogue turn';end if;
 -- Posture/context changes are available to the next request, and the old history remains.
 update public.private_dilemma_sessions set choice='B',context='CONTEXT TWO' where id=s1;
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,next_req,'NOW I CHOOSE B');execute 'reset role';
 lease:=(x->>'lease_id')::uuid;
 if x->'context'->>'choice'<>'B' or x->'context'->>'memory'<>'FIRST MEMORY' or jsonb_array_length(x->'context'->'history')<>1 then raise exception 'Conversation memory or posture lost';end if;
 update public.private_dilemma_sessions set choice='A' where id=s1;
 execute 'set local role service_role';x:=public.finish_private_dialogue(next_req,lease,u1,'STALE REPLY','STALE QUESTION','STALE MEMORY','IA');execute 'reset role';if x->>'status'<>'stale' then raise exception 'Old context reply not blocked';end if;
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,next_req,'NOW I CHOOSE B');execute 'reset role';lease:=(x->>'lease_id')::uuid;if x->'context'->>'choice'<>'A' then raise exception 'Retry did not use latest stance';end if;
 execute 'set local role service_role';x:=public.finish_private_dialogue(next_req,lease,u1,'BASIC REPLY','BASIC QUESTION','UPDATED MEMORY','BASICA');execute 'reset role';if x->>'status'<>'ready' or x->'turn'->>'mode'<>'BASICA' then raise exception 'Fallback missing';end if;
 -- A different profile cannot read, prepare, or delete the dialogue.
 perform set_config('request.jwt.claim.sub',u2::text,true);execute 'set local role authenticated';select count(*) into n from public.private_dilemma_dialogue_turns where session_id=s1;execute 'reset role';if n<>0 then raise exception 'Other user read private dialogue';end if;
 failed:=false;begin execute 'set local role authenticated';perform public.prepare_private_dialogue(s1,gen_random_uuid(),'OTHER USER');exception when others then failed:=SQLERRM='PRIVATE_SESSION_NOT_FOUND';end;execute 'reset role';if not failed then raise exception 'Other user wrote private dialogue';end if;
 -- Lease expiration can be recovered without creating another user message.
 perform set_config('request.jwt.claim.sub',u1::text,true);execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,other_req,'RECOVER THIS');execute 'reset role';
 update public.private_dilemma_dialogue_turns set leased_at=clock_timestamp()-interval '70 seconds' where id=other_req;
 execute 'set local role authenticated';x:=public.prepare_private_dialogue(s1,other_req,'RECOVER THIS');execute 'reset role';lease:=(x->>'lease_id')::uuid;
 if x->>'status'<>'prepared' or (select attempts from public.private_dilemma_dialogue_turns where id=other_req)<>2 then raise exception 'Expired lease not reclaimed';end if;
 execute 'set local role service_role';x:=public.finish_private_dialogue(other_req,lease,u1,'RECOVERED','QUESTION?','RECOVERED MEMORY','IA');execute 'reset role';
 -- Discard cascades through the conversation as well as the old guides.
 execute 'set local role authenticated';delete from public.private_dilemma_sessions where id=s1;execute 'reset role';
 if exists(select 1 from public.private_dilemma_dialogue_turns where session_id=s1) then raise exception 'Discard left dialogue behind';end if;
 execute 'set local role service_role';x:=public.finish_private_dialogue(other_req,lease,u1,'LATE','QUESTION?','MEMORY','IA');execute 'reset role';if x->>'status'<>'discarded' then raise exception 'Completion resurrected discarded session';end if;
 failed:=false;begin execute 'set local role anon';perform public.prepare_private_dialogue(s2,gen_random_uuid(),'ANON');exception when insufficient_privilege then failed:=true;end;execute 'reset role';if not failed then raise exception 'Unauthenticated prepare allowed';end if;
 raise notice 'R93 neutral dialogue, memory, idempotency, concurrency, server-only replies, context/stance changes, fallback, privacy, retries and discard passed';
end $test$;
rollback;
