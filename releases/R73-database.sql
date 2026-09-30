CREATE OR REPLACE FUNCTION private.context_state(p_round bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare room bigint; c text; req private.debate_context_requests; n bigint; y bigint; no_count bigint; myvote boolean; context_count bigint;
begin
 select room_id,context into room,c from public.rounds where id=p_round for update;
 if auth.uid() is null or not exists(select 1 from public.players where room_id=room and user_id=auth.uid() and abandoned_at is null) then raise exception 'Not in room'; end if;
 update private.debate_context_requests r set status='cancelled' where round_id=p_round and status in ('open','approved') and not exists(select 1 from public.players where room_id=room and user_id=r.requester and presence='present' and abandoned_at is null);
 select * into req from private.debate_context_requests where round_id=p_round and status in ('open','approved') order by id desc limit 1;
 select count(*) into n from public.players where room_id=room and presence='present' and abandoned_at is null;
 select count(*) into context_count from private.debate_context_requests where round_id=p_round and status='published';
 if coalesce((select length(p.context)>0 from public.debate_dilemma_proposals p where p.room_id=room and p.status='launched' and p.created_at<=(select created_at from public.rounds where id=p_round) order by p.id desc limit 1),false) then context_count:=context_count+1; end if;
 if req.id is null then return jsonb_build_object('context',c,'count',context_count,'players',n); end if;
 select count(*) filter(where choice),count(*) filter(where not choice) into y,no_count from private.debate_context_votes v join public.players p on p.room_id=room and p.user_id=v.user_id where v.request_id=req.id and p.presence='present' and p.abandoned_at is null;
 if req.status='open' then
  if y>n/2 then update private.debate_context_requests set status='approved' where id=req.id;req.status:='approved';
  elsif no_count>n/2 or y+no_count>=n then update private.debate_context_requests set status='rejected' where id=req.id;return jsonb_build_object('context',c,'count',context_count,'players',n); end if;
 end if;
 select choice into myvote from private.debate_context_votes where request_id=req.id and user_id=auth.uid();
 return jsonb_build_object('context',c,'count',context_count,'players',n,'id',req.id,'status',req.status,'mine',myvote,'requester_me',req.requester=auth.uid(),'voted',y+no_count);
end $function$
