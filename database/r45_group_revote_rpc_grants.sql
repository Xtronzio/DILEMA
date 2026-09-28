-- R45: las tres operaciones del re-voto de la mesa requieren acceso RPC para jugadores autenticados.
grant execute on function public.get_debate_revote_proposal(bigint) to authenticated;
grant execute on function public.propose_debate_revote(bigint) to authenticated;
grant execute on function public.cast_debate_revote_proposal_vote(bigint,text) to authenticated;
