alter table public.private_dilemma_sessions
 drop constraint private_dilemma_sessions_question_check,
 drop constraint private_dilemma_sessions_option_a_check,
 drop constraint private_dilemma_sessions_option_b_check,
 add constraint private_dilemma_sessions_question_check check(length(trim(question)) between 1 and 1000),
 add constraint private_dilemma_sessions_option_a_check check(length(trim(option_a)) between 1 and 500),
 add constraint private_dilemma_sessions_option_b_check check(length(trim(option_b)) between 1 and 500);