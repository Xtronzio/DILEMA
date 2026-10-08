-- Real database regression; all fixtures and changes are rolled back.
begin;
select set_config('r118.owner',gen_random_uuid()::text,true),set_config('r118.other',gen_random_uuid()::text,true);
insert into auth.users(id) values (current_setting('r118.owner')::uuid),(current_setting('r118.other')::uuid);
insert into public.private_dilemma_sessions(user_id,question) values
 (current_setting('r118.owner')::uuid,'R118 TEST PRIVATE'),(current_setting('r118.other')::uuid,'R118 OTHER PRIVATE');
insert into public.saved_group_dilemmas(user_id,source_round_id,question,option_a,option_b) values
 (current_setting('r118.owner')::uuid,-118,'R118 TEST GROUP','A','B'),(current_setting('r118.other')::uuid,-118,'R118 OTHER GROUP','A','B');
select set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('r118.owner'),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare affected integer; owner_id uuid:=current_setting('r118.owner')::uuid; other_id uuid:=current_setting('r118.other')::uuid;
begin
 if (select count(*) from public.saved_dilemma_library)<>2 then raise exception 'R118: view leaked another owner or missed own records'; end if;
 update public.private_dilemma_sessions set is_pinned=true where user_id=owner_id;get diagnostics affected=row_count;
 if affected<>1 then raise exception 'R118: private pin failed'; end if;
 update public.saved_group_dilemmas set is_pinned=true where user_id=owner_id;get diagnostics affected=row_count;
 if affected<>1 then raise exception 'R118: group pin failed'; end if;
 if (select count(*) from public.saved_dilemma_library where is_pinned)<>2 then raise exception 'R118: pin not visible through view'; end if;
 begin
  delete from public.private_dilemma_sessions where user_id=owner_id;
  raise exception 'R118: pinned private deletion was allowed';
 exception when raise_exception then if sqlerrm<>'DILEMMA_PINNED' then raise; end if;
 end;
 begin
  delete from public.saved_group_dilemmas where user_id=owner_id;
  raise exception 'R118: pinned group deletion was allowed';
 exception when raise_exception then if sqlerrm<>'DILEMMA_PINNED' then raise; end if;
 end;
 update public.private_dilemma_sessions set is_pinned=true where user_id=other_id;get diagnostics affected=row_count;
 if affected<>0 then raise exception 'R118: changed another owner private pin'; end if;
 update public.saved_group_dilemmas set is_pinned=true where user_id=other_id;get diagnostics affected=row_count;
 if affected<>0 then raise exception 'R118: changed another owner group pin'; end if;
 begin
  update public.saved_group_dilemmas set question='ALTERED' where user_id=owner_id;
  raise exception 'R118: archive content update allowed';
 exception when insufficient_privilege then null;
 end;
 update public.private_dilemma_sessions set is_pinned=false where user_id=owner_id;
 update public.saved_group_dilemmas set is_pinned=false where user_id=owner_id;
 delete from public.private_dilemma_sessions where user_id=owner_id;get diagnostics affected=row_count;
 if affected<>1 then raise exception 'R118: unpinned private cannot be deleted'; end if;
 delete from public.saved_group_dilemmas where user_id=owner_id;get diagnostics affected=row_count;
 if affected<>1 then raise exception 'R118: unpinned group cannot be deleted'; end if;
 if has_table_privilege('anon','public.saved_dilemma_library','select') then raise exception 'R118: anonymous database role can read private view'; end if;
end $$;
rollback;
select 'PASS R118: authenticated private/group pin, view isolation, foreign updates blocked, protected delete rejected, archive content immutable, unpin then delete; fixtures rolled back' as result;
