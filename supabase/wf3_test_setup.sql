-- =====================================================================
--  AI Recruiting Copilot · Workflow 3 (Test runner) · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf2_search_setup.sql. Safe to run again later.
--
--  WHAT IT ADDS
--    test_questions    the 10 test questions and their right answers
--                      (right answers = the 60-CV test dataset)
--    test_runs         every test run: score out of 10 + each answer
--    save_test_run()   saves a test run, returns it with its run_id
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The 10 test questions and the right answers
-- ---------------------------------------------------------------------
create table if not exists test_questions (
  n                  int primary key,                 -- 1 … 10
  question           text not null,
  expected           jsonb not null default '[]',     -- [{name, cv_file_name, cv_files}] the bot must return exactly these
                                                      -- (cv_files = every file of that person that counts as their CV)
  expect_no_match    boolean not null default false,  -- true = the right answer is "nobody"
  should_not_appear  jsonb not null default '[]',     -- close but wrong: [{name, cv_file_name, why}]
  why_tricky         text,
  updated_at         timestamptz not null default now()
);

insert into test_questions (n, question, expected, expect_no_match, should_not_appear, why_tricky) values
  (1, 'Who has 3+ years of GHL experience and speaks Arabic?',
   '[{"name": "Rania Khoury", "cv_file_name": "Rania Khoury - CV.pdf", "cv_files": ["Rania Khoury - CV.pdf"]}, {"name": "Karim Mansour", "cv_file_name": "CV_Karim_Mansour.docx", "cv_files": ["CV_Karim_Mansour.docx"]}, {"name": "Hussein Ali", "cv_file_name": "Hussein Ali - GHL Specialist.docx", "cv_files": ["Hussein Ali - GHL Specialist.docx"]}, {"name": "Nour El-Din Farag", "cv_file_name": "NourElDin_Farag_Resume.pdf", "cv_files": ["NourElDin_Farag_Resume.pdf"]}]'::jsonb,
   false,
   '[{"name": "Layla Saad", "cv_file_name": "Layla Saad Resume 2026.docx", "why": "has GHL but only 2.3 years", "cv_files": ["Layla Saad Resume 2026.docx"]}, {"name": "Omar Farouk", "cv_file_name": "Omar Farouk.docx", "why": "has GHL but only 1.8 years", "cv_files": ["Omar Farouk.docx"]}, {"name": "Daniel Okafor", "cv_file_name": "daniel_okafor_ghl_cv.pdf", "why": "missing: speaks Arabic", "cv_files": ["daniel_okafor_ghl_cv.pdf"]}, {"name": "Priya Nair", "cv_file_name": "PRIYA_NAIR_RESUME.pdf", "why": "missing: speaks Arabic", "cv_files": ["PRIYA_NAIR_RESUME.pdf"]}, {"name": "Maria Santos", "cv_file_name": "Maria_Santos_CV_final.docx", "why": "missing: speaks Arabic", "cv_files": ["Maria_Santos_CV_final.docx"]}]'::jsonb,
   'GHL is written several ways across the CVs (GoHighLevel, GHL, HighLevel, Go High Level). Two Arabic speakers have GHL but under 3 years.'),
  (2, 'Has anyone run payroll in Gusto?',
   '[{"name": "Mariam Tawfik", "cv_file_name": "Mariam Tawfik - Resume (updated Oct 2026).docx", "cv_files": ["Mariam Tawfik - Resume (updated Oct 2026).docx"]}]'::jsonb,
   false,
   '[]'::jsonb,
   'Only Mariam Tawfik''s UPDATED CV (Oct 2026) mentions Gusto. Her old 2023 CV doesn''t, so the bot must use the newest CV.'),
  (3, 'I need a customer support person with 2+ years of Zendesk who speaks French',
   '[{"name": "Claire Moussa", "cv_file_name": "Claire_Moussa_CV.pdf", "cv_files": ["Claire_Moussa_CV.pdf", "Claire Moussa CV.docx"]}, {"name": "Yara Fakhoury", "cv_file_name": "Yara_Fakhoury_CV.pdf", "cv_files": ["Yara_Fakhoury_CV.pdf", "CV - Yara Fakhoury.docx"]}, {"name": "Amira Benjelloun", "cv_file_name": "Amira Benjelloun CV.docx", "cv_files": ["Amira Benjelloun CV.docx"]}, {"name": "Jean-Pierre Habimana", "cv_file_name": "JP_Habimana_CV.pdf", "cv_files": ["JP_Habimana_CV.pdf"]}]'::jsonb,
   false,
   '[{"name": "Nadia Karam", "cv_file_name": "Nadia Karam CV.pdf", "why": "has Zendesk but only 1.2 years", "cv_files": ["Nadia Karam CV.pdf"]}, {"name": "Ahmed Hassan", "cv_file_name": "Ahmed Hassan CV (support).docx", "why": "missing: speaks French", "cv_files": ["Ahmed Hassan CV (support).docx"]}, {"name": "Kofi Asante", "cv_file_name": "Kofi_Asante_Resume.pdf", "why": "missing: speaks French", "cv_files": ["Kofi_Asante_Resume.pdf", "Kofi_Asante_Resume (1).pdf"]}]'::jsonb,
   'Claire Moussa and Yara Fakhoury each sent their CV twice. Each should appear ONCE.'),
  (4, 'Find me cold callers who speak Tagalog',
   '[{"name": "Jasmine Reyes", "cv_file_name": "scan_jreyes_cv.pdf", "cv_files": ["scan_jreyes_cv.pdf"]}, {"name": "Mark Villanueva", "cv_file_name": "Mark Villanueva - Inside Sales.docx", "cv_files": ["Mark Villanueva - Inside Sales.docx"]}]'::jsonb,
   false,
   '[{"name": "Maria Santos", "cv_file_name": "Maria_Santos_CV_final.docx", "why": "missing: cold callers", "cv_files": ["Maria_Santos_CV_final.docx"]}, {"name": "Kevin Dela Cruz", "cv_file_name": "KDelaCruz_CV.pdf", "why": "missing: cold callers", "cv_files": ["KDelaCruz_CV.pdf"]}, {"name": "Rafael Cruz", "cv_file_name": "Rafael Cruz Resume.docx", "why": "missing: cold callers", "cv_files": ["Rafael Cruz Resume.docx"]}, {"name": "Bilal Ahmed", "cv_file_name": "Bilal Ahmed CV.pdf", "why": "missing: speaks Tagalog", "cv_files": ["Bilal Ahmed CV.pdf"]}, {"name": "Carlos Mendoza", "cv_file_name": "Carlos_Mendoza_CV.pdf", "why": "missing: speaks Tagalog", "cv_files": ["Carlos_Mendoza_CV.pdf"]}]'::jsonb,
   'Jasmine Reyes''s CV is a scanned image with no text layer. If the scan was skipped, she will be missing.'),
  (5, 'Who has 5+ years of Salesforce and speaks German?',
   '[]'::jsonb,
   true,
   '[{"name": "Andrés Gómez", "cv_file_name": "CV Andres Gomez.docx", "why": "missing: speaks German", "cv_files": ["CV Andres Gomez.docx"]}]'::jsonb,
   'Nobody matches. The bot must say so honestly and not invent anyone. Andrés Gómez is the closest (Salesforce, no German).'),
  (6, 'Who knows both Zapier and Make?',
   '[{"name": "Rania Khoury", "cv_file_name": "Rania Khoury - CV.pdf", "cv_files": ["Rania Khoury - CV.pdf"]}, {"name": "Priya Nair", "cv_file_name": "PRIYA_NAIR_RESUME.pdf", "cv_files": ["PRIYA_NAIR_RESUME.pdf"]}, {"name": "Sofia Ramirez", "cv_file_name": "Sofia Ramirez CV (EN).pdf", "cv_files": ["Sofia Ramirez CV (EN).pdf"]}]'::jsonb,
   false,
   '[{"name": "Omar Farouk", "cv_file_name": "Omar Farouk.docx", "why": "missing: Zapier", "cv_files": ["Omar Farouk.docx"]}, {"name": "Daniel Okafor", "cv_file_name": "daniel_okafor_ghl_cv.pdf", "why": "missing: Make", "cv_files": ["daniel_okafor_ghl_cv.pdf"]}, {"name": "Karim Mansour", "cv_file_name": "CV_Karim_Mansour.docx", "why": "missing: Make", "cv_files": ["CV_Karim_Mansour.docx"]}]'::jsonb,
   '"Make" is also an ordinary English word. Only people with the Make.com tool count.'),
  (7, 'Who has run Facebook ads for real estate?',
   '[{"name": "Gabriela Torres", "cv_file_name": "Gabriela Torres - Paid Social.docx", "cv_files": ["Gabriela Torres - Paid Social.docx"]}, {"name": "Rafael Cruz", "cv_file_name": "Rafael Cruz Resume.docx", "cv_files": ["Rafael Cruz Resume.docx"]}, {"name": "Youssef Haddad", "cv_file_name": "Youssef-Haddad-CV-2026.pdf", "cv_files": ["Youssef-Haddad-CV-2026.pdf"]}]'::jsonb,
   false,
   '[{"name": "Vikram Shah", "cv_file_name": "Vikram_Shah_PPC_CV.docx", "why": "missing: \"real estate\" in CV", "cv_files": ["Vikram_Shah_PPC_CV.docx"]}, {"name": "Dina Rahal", "cv_file_name": "Dina_Rahal_CV.pdf", "why": "missing: \"real estate\" in CV", "cv_files": ["Dina_Rahal_CV.pdf"]}, {"name": "Hannah Abebe", "cv_file_name": "Hannah Abebe CV.pdf", "why": "missing: \"real estate\" in CV", "cv_files": ["Hannah Abebe CV.pdf"]}, {"name": "Ibrahima Diallo", "cv_file_name": "Ibrahima Diallo CV.pdf", "why": "missing: \"real estate\" in CV", "cv_files": ["Ibrahima Diallo CV.pdf"]}, {"name": "Camila Rojas", "cv_file_name": "Camila Rojas CV.pdf", "why": "missing: \"real estate\" in CV", "cv_files": ["Camila Rojas CV.pdf"]}]'::jsonb,
   'Youssef Haddad only qualifies on his UPDATED CV (2026). His old 2024 CV has no real estate work.'),
  (8, 'Any bookkeepers in Egypt who use Xero?',
   '[{"name": "Mariam Tawfik", "cv_file_name": "Mariam Tawfik - Resume (updated Oct 2026).docx", "cv_files": ["Mariam Tawfik - Resume (updated Oct 2026).docx"]}, {"name": "Ahmed Hassan", "cv_file_name": "Ahmed_Hassan_Bookkeeper.pdf", "cv_files": ["Ahmed_Hassan_Bookkeeper.pdf"]}]'::jsonb,
   false,
   '[{"name": "Mohamed Adel", "cv_file_name": "Mohamed Adel Resume.pdf", "why": "missing: Xero", "cv_files": ["Mohamed Adel Resume.pdf"]}, {"name": "Nour El-Din Farag", "cv_file_name": "NourElDin_Farag_Resume.pdf", "why": "missing: Xero", "cv_files": ["NourElDin_Farag_Resume.pdf"]}, {"name": "Ana Lima", "cv_file_name": "Ana Lima - Bookkeeper.docx", "why": "missing: in Egypt", "cv_files": ["Ana Lima - Bookkeeper.docx"]}, {"name": "Hira Siddiqui", "cv_file_name": "Hira Siddiqui CV.pdf", "why": "missing: in Egypt", "cv_files": ["Hira Siddiqui CV.pdf"]}, {"name": "Reem Al-Masri", "cv_file_name": "Reem_AlMasri_CV.docx", "why": "missing: in Egypt", "cv_files": ["Reem_AlMasri_CV.docx"]}]'::jsonb,
   'There are two people called Ahmed Hassan: the bookkeeper in Cairo (correct) and a support agent in Amman (wrong).'),
  (9, 'Who has 6+ years of customer support experience and knows Shopify?',
   '[{"name": "Patricia Wanjiru", "cv_file_name": "Patricia Wanjiru - Customer Support.pdf", "cv_files": ["Patricia Wanjiru - Customer Support.pdf"]}, {"name": "Ricardo Silva", "cv_file_name": "Ricardo Silva CV.docx", "cv_files": ["Ricardo Silva CV.docx"]}]'::jsonb,
   false,
   '[{"name": "Meera Iyer", "cv_file_name": "Meera_Iyer_CV.docx", "why": "has customer support but only 5 years", "cv_files": ["Meera_Iyer_CV.docx"]}, {"name": "Claire Moussa", "cv_file_name": "Claire_Moussa_CV.pdf", "why": "has customer support but only 5 years", "cv_files": ["Claire_Moussa_CV.pdf", "Claire Moussa CV.docx"]}, {"name": "Kofi Asante", "cv_file_name": "Kofi_Asante_Resume.pdf", "why": "has customer support but only 3.8 years", "cv_files": ["Kofi_Asante_Resume.pdf", "Kofi_Asante_Resume (1).pdf"]}, {"name": "Amira Benjelloun", "cv_file_name": "Amira Benjelloun CV.docx", "why": "has customer support but only 3.5 years", "cv_files": ["Amira Benjelloun CV.docx"]}, {"name": "Ahmed Hassan", "cv_file_name": "Ahmed Hassan CV (support).docx", "why": "missing: Shopify", "cv_files": ["Ahmed Hassan CV (support).docx"]}]'::jsonb,
   'Years must be counted for customer support, not total work. Meera Iyer and Claire Moussa have 5 years of support (but 7+ years of work in total).'),
  (10, 'Anyone with 8+ years of GoHighLevel?',
   '[]'::jsonb,
   true,
   '[{"name": "Daniel Okafor", "cv_file_name": "daniel_okafor_ghl_cv.pdf", "why": "has GoHighLevel but only 6.9 years", "cv_files": ["daniel_okafor_ghl_cv.pdf"]}, {"name": "Rania Khoury", "cv_file_name": "Rania Khoury - CV.pdf", "why": "has GoHighLevel but only 5.8 years", "cv_files": ["Rania Khoury - CV.pdf"]}, {"name": "Priya Nair", "cv_file_name": "PRIYA_NAIR_RESUME.pdf", "why": "has GoHighLevel but only 5.2 years", "cv_files": ["PRIYA_NAIR_RESUME.pdf"]}, {"name": "Maria Santos", "cv_file_name": "Maria_Santos_CV_final.docx", "why": "has GoHighLevel but only 4.8 years", "cv_files": ["Maria_Santos_CV_final.docx"]}, {"name": "Zainab Bello", "cv_file_name": "Zainab Bello CV.pdf", "why": "has GoHighLevel but only 4.8 years", "cv_files": ["Zainab Bello CV.pdf"]}]'::jsonb,
   'Nobody matches. The bot must say so and not stretch the numbers. The longest is Daniel Okafor with about 7 years.')
on conflict (n) do update set
  question = excluded.question, expected = excluded.expected, expect_no_match = excluded.expect_no_match,
  should_not_appear = excluded.should_not_appear, why_tricky = excluded.why_tricky, updated_at = now();

-- ---------------------------------------------------------------------
-- 2. Test runs
-- ---------------------------------------------------------------------
create table if not exists test_runs (
  id       bigint generated always as identity primary key,
  ran_at   timestamptz not null default now(),
  score    int not null,                 -- questions right
  total    int not null,                 -- questions asked
  results  jsonb not null default '[]'   -- one entry per question: right answer, bot's answer, right or wrong, why
);
create index if not exists test_runs_ran_at_idx on test_runs (ran_at desc);

create or replace function save_test_run(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_id bigint;
begin
  insert into test_runs (score, total, results)
  values ((p->>'score')::int, (p->>'total')::int, coalesce(p->'results', '[]'::jsonb))
  returning id into v_id;
  return p || jsonb_build_object('run_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- 3. Security: keep these away from the public "anon" key
-- ---------------------------------------------------------------------
alter table test_questions enable row level security;
alter table test_runs enable row level security;
revoke execute on function save_test_run(jsonb) from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function save_test_run(jsonb) from %I', r);
    end if;
  end loop;
end $$;

select 'Workflow 3 database is ready ✅' as status, (select count(*) from test_questions) as test_questions;
