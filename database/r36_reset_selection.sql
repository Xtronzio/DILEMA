create or replace function public.debate_reset_selection(p_room bigint)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r public.rooms;
begin
  select * into r from public.rooms where id=p_room for update;
  if r.id is null or r.mode <> 'debate' or r.status <> 'waiting'
     or auth.uid() is null
     or not exists (
       select 1 from public.players
       where room_id=p_room and user_id=auth.uid()
         and player_id=r.host_id and abandoned_at is null and presence='present'
     ) then
    raise exception 'Solo el anfitrión puede reiniciar la elección antes del debate';
  end if;
  delete from public.debate_dilemma_proposals
   where room_id=p_room and status in ('open','accepted','rejected');
  delete from public.debate_selections where room_id=p_room;
end
$function$;
revoke all on function public.debate_reset_selection(bigint) from public, anon;
grant execute on function public.debate_reset_selection(bigint) to authenticated;