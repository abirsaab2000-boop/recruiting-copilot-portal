-- =====================================================================
--  AI Recruiting Copilot · Workflow 2 (Search) · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf1_database_setup.sql. Safe to run again later.
--
--  WHAT IT ADDS
--    searches            every question asked and the answer given (audit trail)
--    skill_vocabulary()  the skills and languages in the database, so the AI
--                        uses the same names ("gohighlevel", not "GHL")
--    search_candidates() applies the hard requirements and explains what failed
--    log_search()        saves the question + answer, returns the answer
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Every search, kept for the audit trail and the portal
-- ---------------------------------------------------------------------
create table if not exists searches (
  id         bigint generated always as identity primary key,
  asked_at   timestamptz not null default now(),
  source     text not null default 'manual',   -- slack | test | shortlist | manual
  asked_by   text,
  question   text,
  summary    text,                             -- the question, as the AI understood it
  filters    jsonb,
  status     text,                             -- matches | no_match | no_strong_match | not_a_question | error
  message    text,                             -- the answer the recruiter saw
  results    jsonb                             -- the candidates shown, with scores
);
create index if not exists searches_asked_at_idx on searches (asked_at desc);

-- ---------------------------------------------------------------------
-- 2. skill_vocabulary(): what the database knows about
-- ---------------------------------------------------------------------
create or replace function skill_vocabulary() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'people', (select count(*) from candidates c
                 join cv_documents d on d.id = c.current_cv_id and d.is_current),
    'skills', coalesce((
      select jsonb_agg(jsonb_build_object('skill', skill, 'people', people) order by people desc, skill)
        from (select s.skill, count(distinct s.candidate_id) as people
                from candidate_skills s
                join candidates c   on c.id = s.candidate_id
                join cv_documents d on d.id = c.current_cv_id and d.is_current
               group by s.skill) t), '[]'::jsonb),
    'languages', coalesce((
      select jsonb_agg(language order by language)
        from (select distinct unnest(c.languages) as language
                from candidates c
                join cv_documents d on d.id = c.current_cv_id and d.is_current) l), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------
-- 3. search_candidates(filters)
--
--   filters = {
--     "must_skills":     [{"skill": "gohighlevel", "asked_as": "GHL", "min_years": 3}],
--     "languages":       ["arabic"],
--     "min_total_years": 5,
--     "locations":       ["lebanon"],          -- any of these, matched against location
--     "must_keywords":   ["dental"],           -- must appear somewhere in the CV text
--     "limit":           15
--   }
--
--   Only people whose CURRENT CV passes every requirement are returned.
--   For each requirement it also counts how many people pass it on its own,
--   so "no match" answers can explain exactly what is missing.
-- ---------------------------------------------------------------------
create or replace function search_candidates(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_limit   int := least(greatest(coalesce((p->>'limit')::int, 15), 1), 30);
  v_pool    uuid[];
  v_ids     uuid[];
  v_set     uuid[];
  v_reqs    jsonb := '[]'::jsonb;    -- [{label, people, ids}]
  v_label   text;
  v_lang    text;
  v_kw      text;
  v_locs    text[];
  v_years   numeric;
  v_skill   record;
  v_matches jsonb;
  v_near    jsonb := '[]'::jsonb;
begin
  -- Everyone with a current, searchable CV
  select coalesce(array_agg(c.id), '{}') into v_pool
    from candidates c
    join cv_documents d on d.id = c.current_cv_id and d.is_current and d.status = 'indexed';
  v_ids := v_pool;

  -- a) skills, with optional minimum years
  for v_skill in
    select lower(trim(x->>'skill')) as skill,
           coalesce(nullif(trim(x->>'asked_as'), ''), x->>'skill') as asked_as,
           nullif(x->>'min_years', '')::numeric as min_years
      from jsonb_array_elements(coalesce(p->'must_skills', '[]'::jsonb)) x
     where coalesce(trim(x->>'skill'), '') <> ''
  loop
    select coalesce(array_agg(distinct s.candidate_id), '{}') into v_set
      from candidate_skills s
     where s.candidate_id = any(v_pool)
       and s.skill = v_skill.skill
       and (v_skill.min_years is null or s.years >= v_skill.min_years);
    v_label := case when v_skill.min_years is null then v_skill.asked_as
                    else format('%s+ years of %s', trim_scale(v_skill.min_years), v_skill.asked_as) end;
    v_reqs := v_reqs || jsonb_build_object('label', v_label, 'people', cardinality(v_set), 'ids', to_jsonb(v_set));
    v_ids := array(select unnest(v_ids) intersect select unnest(v_set));
  end loop;

  -- b) languages
  for v_lang in select lower(trim(x)) from jsonb_array_elements_text(coalesce(p->'languages', '[]'::jsonb)) x where trim(x) <> '' loop
    select coalesce(array_agg(c.id), '{}') into v_set
      from candidates c where c.id = any(v_pool) and v_lang = any(c.languages);
    v_reqs := v_reqs || jsonb_build_object('label', 'speaks ' || initcap(v_lang), 'people', cardinality(v_set), 'ids', to_jsonb(v_set));
    v_ids := array(select unnest(v_ids) intersect select unnest(v_set));
  end loop;

  -- c) total years of experience
  v_years := nullif(p->>'min_total_years', '')::numeric;
  if v_years is not null and v_years > 0 then
    select coalesce(array_agg(c.id), '{}') into v_set
      from candidates c where c.id = any(v_pool) and c.total_years >= v_years;
    v_reqs := v_reqs || jsonb_build_object('label', format('%s+ years of experience in total', trim_scale(v_years)),
                                           'people', cardinality(v_set), 'ids', to_jsonb(v_set));
    v_ids := array(select unnest(v_ids) intersect select unnest(v_set));
  end if;

  -- d) location (any of the places asked for)
  v_locs := array(select lower(trim(x)) from jsonb_array_elements_text(coalesce(p->'locations', '[]'::jsonb)) x where trim(x) <> '');
  if cardinality(v_locs) > 0 then
    select coalesce(array_agg(c.id), '{}') into v_set
      from candidates c
     where c.id = any(v_pool)
       and exists (select 1 from unnest(v_locs) l where c.location ilike '%' || l || '%' or c.timezone ilike '%' || l || '%');
    v_reqs := v_reqs || jsonb_build_object('label', 'based in ' || array_to_string(array(select initcap(l) from unnest(v_locs) l), ' or '),
                                           'people', cardinality(v_set), 'ids', to_jsonb(v_set));
    v_ids := array(select unnest(v_ids) intersect select unnest(v_set));
  end if;

  -- e) words that must appear in the CV
  for v_kw in select lower(trim(x)) from jsonb_array_elements_text(coalesce(p->'must_keywords', '[]'::jsonb)) x where trim(x) <> '' loop
    select coalesce(array_agg(c.id), '{}') into v_set
      from candidates c
      join cv_documents d on d.id = c.current_cv_id
     where c.id = any(v_pool) and d.text_content ilike '%' || v_kw || '%';
    v_reqs := v_reqs || jsonb_build_object('label', format('mentions "%s"', v_kw), 'people', cardinality(v_set), 'ids', to_jsonb(v_set));
    v_ids := array(select unnest(v_ids) intersect select unnest(v_set));
  end loop;

  -- The people who pass everything, strongest on the asked-for skills first
  select coalesce(jsonb_agg(m order by m.rank_years desc, m.total_years desc nulls last, m.full_name), '[]'::jsonb)
    into v_matches
    from (
      select c.id as candidate_id,
             c.full_name,
             c.headline,
             c.location,
             c.timezone,
             c.total_years,
             c.language_details as languages,
             coalesce((select sum(s.years) from candidate_skills s
                        where s.candidate_id = c.id
                          and s.skill in (select lower(trim(x->>'skill')) from jsonb_array_elements(coalesce(p->'must_skills', '[]'::jsonb)) x)), 0) as rank_years,
             coalesce((select jsonb_agg(jsonb_build_object('skill', s.skill, 'label', s.label, 'years', s.years, 'evidence', s.evidence)
                                        order by s.years desc nulls last, s.skill)
                         from (select * from candidate_skills s2 where s2.candidate_id = c.id
                                order by s2.years desc nulls last limit 30) s), '[]'::jsonb) as skills,
             coalesce((select jsonb_agg(j) from (select j from jsonb_array_elements(coalesce(d.profile->'jobs', '[]'::jsonb)) j limit 5) jj), '[]'::jsonb) as recent_jobs,
             d.id          as cv_id,
             d.file_name   as cv_file_name,
             d.file_url    as cv_file_url,
             d.flags       as cv_flags,
             left(coalesce(d.text_content, ''), 3000) as cv_excerpt
        from candidates c
        join cv_documents d on d.id = c.current_cv_id
       where c.id = any(v_ids)
       order by 8 desc, c.total_years desc nulls last, c.full_name
       limit v_limit
    ) m;

  -- Nobody passes everything? Show who misses only ONE requirement (they are real, just not a full match)
  if cardinality(v_ids) = 0 and jsonb_array_length(v_reqs) >= 2 then
    select coalesce(jsonb_agg(jsonb_build_object('candidate_id', t.id, 'full_name', t.full_name, 'missing', t.missing[1])
                              order by t.full_name), '[]'::jsonb)
      into v_near
      from (
        select c.id, c.full_name,
               array_agg(q->>'label') filter (where not (q->'ids') ? c.id::text) as missing
          from candidates c
          cross join jsonb_array_elements(v_reqs) q
         where c.id = any(v_pool)
         group by c.id, c.full_name
        having count(*) filter (where not (q->'ids') ? c.id::text) = 1
         order by c.full_name
         limit 3
      ) t;
  end if;

  return jsonb_build_object(
    'pool', cardinality(v_pool),
    'total_matches', cardinality(v_ids),
    'matches', v_matches,
    'checks', coalesce((select jsonb_agg(jsonb_build_object('label', r->>'label', 'people', (r->>'people')::int))
                          from jsonb_array_elements(v_reqs) r), '[]'::jsonb),
    'near_misses', v_near
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. log_search(answer): saves the search and hands the answer back
-- ---------------------------------------------------------------------
create or replace function log_search(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_id bigint;
begin
  insert into searches (source, asked_by, question, summary, filters, status, message, results)
  values (coalesce(nullif(p->>'source', ''), 'manual'), p->>'asked_by', p->>'question', p->>'summary',
          p->'filters', p->>'status', p->>'message', coalesce(p->'candidates', '[]'::jsonb))
  returning id into v_id;
  return p || jsonb_build_object('search_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- 5. Security: keep these away from the public "anon" key
-- ---------------------------------------------------------------------
alter table searches enable row level security;
revoke execute on function skill_vocabulary()       from public;
revoke execute on function search_candidates(jsonb) from public;
revoke execute on function log_search(jsonb)        from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function skill_vocabulary(), search_candidates(jsonb), log_search(jsonb) from %I', r);
    end if;
  end loop;
end $$;

select 'Workflow 2 database is ready ✅' as status, skill_vocabulary()->'people' as searchable_people;
