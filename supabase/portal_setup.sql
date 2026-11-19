-- =====================================================================
--  AI Recruiting Copilot · Recruiter portal · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf5_shortlist_setup.sql. Safe to run again later.
--
--  WHAT IT ADDS
--    portal_* views   exactly what the portal shows, and nothing more
--                     (no phone numbers, no full CV text)
--
--  WHO CAN READ THEM
--    Only people who LOG IN to the portal (Supabase "authenticated" users).
--    The public "anon" key alone reads nothing. Turn off public sign-ups in
--    Supabase (Authentication → Sign In / Providers) so only the logins you
--    create yourself can get in.
--
--  Note: Supabase's advisor may call these "security definer views". That is
--  on purpose: the views read the tables for the logged-in user, who has no
--  access to the tables themselves.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Overview numbers (one row)
-- ---------------------------------------------------------------------
create or replace view public.portal_overview as
select
  (select count(*) from candidates where current_cv_id is not null)                          as candidates,
  (select count(*) from cv_documents)                                                       as cv_files,
  (select count(*) from cv_documents where status in ('unreadable', 'unsupported', 'not_a_cv', 'error')) as flagged_files,
  (select count(*) from cv_documents where status in ('duplicate', 'exact_duplicate'))      as duplicate_files,
  (select count(*) from cv_documents where status = 'superseded')                           as replaced_files,
  (select count(*) from cv_documents where 'read_from_scan' = any(flags))                   as scanned_files,
  (select count(*) from candidates where possible_duplicate_of is not null)                 as same_name_checks,
  (select count(*) from roles)                                                              as roles_total,
  (select count(*) from roles where status = 'approved')                                    as roles_open,
  (select count(*) from roles where status = 'pending_approval')                            as roles_pending,
  (select count(*) from shortlist)                                                          as shortlisted,
  (select count(*) from shortlist where status = 'waiting_approval')                        as awaiting_approval,
  (select count(*) from shortlist where status = 'approved')                                as approved_candidates,
  (select count(*) from shortlist where stage is not null)                                  as in_pipeline,
  (select score from test_runs order by ran_at desc limit 1)                                as latest_test_score,
  (select total from test_runs order by ran_at desc limit 1)                                as latest_test_total,
  (select ran_at from test_runs order by ran_at desc limit 1)                               as latest_test_at,
  (select count(*) from searches where asked_at > now() - interval '7 days')                as searches_7d;

-- ---------------------------------------------------------------------
-- Roles (every job description, any status)
-- ---------------------------------------------------------------------
create or replace view public.portal_roles as
select r.id as role_id, r.created_at, r.client_company, r.client_contact, r.role_title, r.hires,
       r.status, r.decided_at, r.jd, r.jd_text, r.open_questions, r.search_question,
       count(s.id)                                              as shortlisted,
       count(s.id) filter (where s.status = 'waiting_approval') as awaiting_approval,
       count(s.id) filter (where s.status = 'approved')         as approved,
       count(s.id) filter (where s.status = 'declined')         as declined
  from roles r
  left join shortlist s on s.role_id = r.id
 group by r.id;

-- ---------------------------------------------------------------------
-- Shortlists + pipeline (one row per candidate per role)
--   board_column = where the candidate sits on the pipeline board
-- ---------------------------------------------------------------------
create or replace view public.portal_shortlist as
select s.id as shortlist_id, s.role_id, r.role_title, r.client_company,
       s.rank, s.score, s.score_parts, s.why_fit, s.gap_or_risk,
       s.cv_file_name, s.cv_file_url,
       s.status as decision, s.decided_at, s.stage, s.ghl_mode, s.sent_to_ghl_at, s.created_at,
       case when s.status = 'waiting_approval' then 'awaiting_approval'
            when s.status = 'declined' then 'declined'
            else coalesce(s.stage, 'approved') end as board_column,
       c.full_name, c.headline, c.location, c.languages, c.total_years
  from shortlist s
  join roles r      on r.id = s.role_id
  join candidates c on c.id = s.candidate_id;

-- ---------------------------------------------------------------------
-- CV library (every file received, including duplicates and flagged files)
-- ---------------------------------------------------------------------
create or replace view public.portal_cv_files as
select d.id as cv_id, d.created_at as received_at, d.file_name, d.file_url, d.mime_type,
       d.status, d.flags, d.status_reason, d.is_current, d.extraction_method, d.cv_latest_date,
       c.full_name as candidate_name, c.location as candidate_location,
       dup.file_name as duplicate_of_file, rep.file_name as replaced_by_file,
       pd.full_name || coalesce(' in ' || pd.location, '') as same_name_as
  from cv_documents d
  left join candidates   c   on c.id   = d.candidate_id
  left join candidates   pd  on pd.id  = c.possible_duplicate_of
  left join cv_documents dup on dup.id = d.duplicate_of
  left join cv_documents rep on rep.id = d.replaced_by;

-- ---------------------------------------------------------------------
-- Test page
-- ---------------------------------------------------------------------
create or replace view public.portal_test_questions as
select n, question, expected, expect_no_match, should_not_appear, why_tricky from test_questions;

create or replace view public.portal_test_runs as
select id as run_id, ran_at, score, total, results from test_runs;

-- ---------------------------------------------------------------------
-- Recent searches (Slack bot, test runner, shortlists)
-- ---------------------------------------------------------------------
create or replace view public.portal_searches as
select id as search_id, asked_at, source, question, summary, status,
       jsonb_array_length(coalesce(results, '[]'::jsonb)) as results_count
  from searches;

-- ---------------------------------------------------------------------
-- Who can read: logged-in portal users only
-- ---------------------------------------------------------------------
do $$
declare
  v text;
  views text[] := array['portal_overview', 'portal_roles', 'portal_shortlist', 'portal_cv_files',
                        'portal_test_questions', 'portal_test_runs', 'portal_searches'];
begin
  foreach v in array views loop
    execute format('revoke all on public.%I from public', v);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on public.%I from anon', v);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on public.%I from authenticated', v);
      execute format('grant select on public.%I to authenticated', v);
    end if;
  end loop;
end $$;

select 'Portal database is ready ✅' as status,
       (select count(*) from public.portal_roles) as roles,
       (select count(*) from public.portal_cv_files) as cv_files,
       (select count(*) from public.portal_test_questions) as test_questions;
