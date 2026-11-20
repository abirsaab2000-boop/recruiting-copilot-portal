-- =====================================================================
--  AI Recruiting Copilot · Workflow 1 (CV intake) · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  It is safe to run again later (it only adds what is missing and
--  refreshes the two functions).
--
--  WHAT IT CREATES
--    candidates        one row per real person
--    cv_documents      one row per CV file ever seen, including bad ones
--    candidate_skills  skills + years from each person's current CV
--    activity_log      what happened to each file, in order
--    cv_check_file()   "have we seen this exact file before?"  (cheap check)
--    ingest_cv()       "who is this person? new, duplicate or update?"
--    cv_library        view: every file and its status (for the portal)
--    searchable_candidates  view: current people + their current CV
--
--  TO START OVER WHILE TESTING (deletes all CV data!), run only this line:
--    truncate activity_log, candidate_skills, cv_documents, candidates restart identity cascade;
-- =====================================================================

create extension if not exists pgcrypto;   -- for gen_random_uuid()

-- ---------------------------------------------------------------------
-- 1. People
-- ---------------------------------------------------------------------
create table if not exists candidates (
  id                    uuid primary key default gen_random_uuid(),
  full_name             text not null,
  name_key              text not null,                 -- name in lowercase, no accents (to spot same-name cases)
  emails                text[] not null default '{}',
  phones                text[] not null default '{}',
  phone_keys            text[] not null default '{}',  -- phone digits without leading zeros (+961 3 456 789 → 9613456789)
  linkedin              text,
  location              text,
  timezone              text,
  headline              text,
  summary               text,
  languages             text[] not null default '{}',  -- e.g. {arabic,english}
  language_details      jsonb  not null default '[]',  -- e.g. [{"language":"arabic","level":"native"}]
  total_years           numeric(4,1),                  -- years of work experience, from job dates
  current_cv_id         uuid,                          -- the CV version that search should use
  possible_duplicate_of uuid references candidates(id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. CV files (every file gets a row, so nothing is ever silently skipped)
-- ---------------------------------------------------------------------
create table if not exists cv_documents (
  id                  uuid primary key default gen_random_uuid(),
  candidate_id        uuid references candidates(id) on delete set null,
  drive_file_id       text not null,
  content_key         text not null,           -- Drive's checksum of the file: same key = identical file
  file_name           text not null,
  file_url            text,
  mime_type           text,
  size_bytes          bigint,
  status              text not null check (status in (
                        'indexed',          -- searchable (only if is_current)
                        'duplicate',        -- same person, same CV (e.g. PDF + Word copy)
                        'exact_duplicate',  -- byte-for-byte copy of another file
                        'superseded',       -- an older version of someone's CV
                        'unreadable',       -- flagged: could not read it
                        'unsupported',      -- flagged: file type we can't read
                        'not_a_cv',         -- flagged: not a CV
                        'error')),          -- flagged: something broke; retried on the next run
  is_current          boolean not null default false,
  flags               text[] not null default '{}',   -- e.g. {read_from_scan, possible_duplicate}
  status_reason       text,
  extraction_method   text,                    -- pdf_text | word_text | pdf_scan | image_scan
  text_content        text,                    -- full CV text (for search)
  profile             jsonb,                   -- everything Claude extracted, cleaned
  cv_latest_date      date,                    -- newest date written in the CV (to tell versions apart)
  content_fingerprint text,                    -- jobs + education summary (to tell duplicates apart)
  duplicate_of        uuid references cv_documents(id) on delete set null,
  replaced_by         uuid references cv_documents(id) on delete set null,
  search_text         tsvector generated always as (to_tsvector('simple', coalesce(text_content, ''))) stored,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (drive_file_id, content_key)
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'candidates_current_cv_fk') then
    alter table candidates add constraint candidates_current_cv_fk
      foreign key (current_cv_id) references cv_documents(id) on delete set null;
  end if;
end $$;

-- A person can only have one current CV
create unique index if not exists one_current_cv_per_candidate on cv_documents (candidate_id) where is_current;

-- ---------------------------------------------------------------------
-- 3. Skills (rebuilt from the person's current CV every time it changes)
-- ---------------------------------------------------------------------
create table if not exists candidate_skills (
  candidate_id    uuid not null references candidates(id) on delete cascade,
  cv_id           uuid not null references cv_documents(id) on delete cascade,
  skill           text not null,          -- normalized, e.g. 'gohighlevel'
  label           text,                   -- as written on the CV, e.g. 'GHL'
  years           numeric(4,1),           -- best estimate (larger of the two below)
  years_from_jobs numeric(4,1),           -- counted from the dates of jobs that mention it
  years_stated    numeric(4,1),           -- what the CV itself claims
  evidence        text,
  primary key (candidate_id, skill)
);

-- ---------------------------------------------------------------------
-- 4. Activity log
-- ---------------------------------------------------------------------
create table if not exists activity_log (
  id           bigint generated always as identity primary key,
  happened_at  timestamptz not null default now(),
  workflow     text not null default 'wf1_cv_intake',
  event        text not null,
  file_name    text,
  cv_id        uuid,
  candidate_id uuid,
  details      jsonb
);

create index if not exists cv_documents_search_idx      on cv_documents using gin (search_text);
create index if not exists cv_documents_content_key_idx on cv_documents (content_key);
create index if not exists candidates_emails_idx        on candidates using gin (emails);
create index if not exists candidates_phone_keys_idx    on candidates using gin (phone_keys);
create index if not exists candidates_languages_idx     on candidates using gin (languages);
create index if not exists candidates_name_key_idx      on candidates (name_key);
create index if not exists candidate_skills_skill_idx   on candidate_skills (skill, years);

-- ---------------------------------------------------------------------
-- 5. cv_check_file(file)  — runs BEFORE we download or pay for AI
--    Returns next_step = 'process' or 'skip' (with outcome + message).
-- ---------------------------------------------------------------------
create or replace function cv_check_file(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_file_id text := p->>'drive_file_id';
  v_key     text := p->>'content_key';
  v_name    text := coalesce(p->>'file_name', '(no name)');
  v_same    cv_documents%rowtype;
  v_orig    record;
  v_new_id  uuid;
  v_msg     text;
begin
  if v_file_id is null or v_key is null then
    raise exception 'cv_check_file needs drive_file_id and content_key. Got: %', p;
  end if;
  perform pg_advisory_xact_lock(hashtext('wf1_cv_intake'));   -- one file at a time

  -- a) This same file, with the same content, was already handled
  select * into v_same from cv_documents
   where drive_file_id = v_file_id and content_key = v_key and status <> 'error'
   limit 1;
  if found then
    update cv_documents set file_name = v_name, file_url = coalesce(p->>'file_url', file_url), updated_at = now()
     where id = v_same.id;
    return jsonb_build_object(
      'next_step', 'skip', 'outcome', 'already_processed',
      'message', format('Already in the database (%s)', replace(v_same.status, '_', ' ')),
      'file_name', v_name, 'file_url', p->>'file_url', 'cv_id', v_same.id, 'candidate_id', v_same.candidate_id,
      'flags', '[]'::jsonb);
  end if;

  -- b) A different file with byte-for-byte the same content
  select d.id, d.file_name, d.status, d.candidate_id, c.full_name into v_orig
    from cv_documents d left join candidates c on c.id = d.candidate_id
   where d.content_key = v_key and d.drive_file_id <> v_file_id
     and d.status not in ('error', 'exact_duplicate')
   order by d.created_at
   limit 1;
  if found then
    v_msg := format('Identical copy of %s', v_orig.file_name)
          || coalesce(' (' || v_orig.full_name || ')', '')
          || case when v_orig.status in ('unreadable', 'unsupported', 'not_a_cv')
                  then ', which was flagged as ' || replace(v_orig.status, '_', ' ') else '' end
          || '. Not processed again.';
    delete from cv_documents where drive_file_id = v_file_id and content_key = v_key and status = 'error';
    insert into cv_documents (candidate_id, drive_file_id, content_key, file_name, file_url, mime_type, size_bytes,
                              status, is_current, status_reason, duplicate_of)
    values (v_orig.candidate_id, v_file_id, v_key, v_name, p->>'file_url', p->>'mime_type', (p->>'size_bytes')::bigint,
            'exact_duplicate', false, v_msg, v_orig.id)
    returning id into v_new_id;
    insert into activity_log (event, file_name, cv_id, candidate_id, details)
    values ('exact_duplicate', v_name, v_new_id, v_orig.candidate_id, jsonb_build_object('copy_of', v_orig.file_name));
    return jsonb_build_object(
      'next_step', 'skip', 'outcome', 'exact_duplicate', 'message', v_msg,
      'file_name', v_name, 'file_url', p->>'file_url', 'cv_id', v_new_id,
      'candidate_id', v_orig.candidate_id, 'candidate_name', v_orig.full_name, 'flags', '[]'::jsonb);
  end if;

  return jsonb_build_object('next_step', 'process', 'file_name', v_name);
end $$;

-- ---------------------------------------------------------------------
-- 6. ingest_cv(payload)  — saves the result of reading one file
--
--   payload.kind = 'flagged'   → record the problem file (unreadable, unsupported, not_a_cv, error)
--   payload.kind = 'extracted' → find the person and decide:
--       new_candidate      nobody matches
--       possible_duplicate nobody matches, but someone has the same name (flagged for a human)
--       updated            same person, this CV is newer → it replaces the old one
--       older_version      same person, this CV is older → stored, but the newer one stays active
--       duplicate          same person, same CV (e.g. a PDF and a Word copy)
--   "Same person" = same email, or same LinkedIn, or same phone + same first name.
-- ---------------------------------------------------------------------
create or replace function ingest_cv(p jsonb) returns jsonb
language plpgsql as $$
declare
  f            jsonb := coalesce(p->'file', '{}'::jsonb);
  v_kind       text  := p->>'kind';
  v_file_id    text  := f->>'drive_file_id';
  v_key        text  := f->>'content_key';
  v_file_name  text  := coalesce(f->>'file_name', '(no name)');
  v_status     text;
  v_cv_id      uuid;
  v_cand       candidates%rowtype;
  v_cur        cv_documents%rowtype;
  v_twin       candidates%rowtype;
  v_found      boolean := false;
  v_has_twin   boolean := false;
  v_emails     text[];
  v_phones     text[];
  v_phone_keys text[];
  v_languages  text[];
  v_linkedin   text;
  v_name       text;
  v_name_key   text;
  v_new_date   date;
  v_fp         text;
  v_outcome    text;
  v_message    text;
  v_flags      text[];
  v_old_file   text;
begin
  if v_file_id is null or v_key is null then
    raise exception 'ingest_cv needs file.drive_file_id and file.content_key. Got: %', f;
  end if;
  perform pg_advisory_xact_lock(hashtext('wf1_cv_intake'));   -- one file at a time

  -- A retry replaces an earlier failed attempt for the same file
  delete from cv_documents where drive_file_id = v_file_id and content_key = v_key and status = 'error';

  -- Already saved (e.g. the workflow was run twice at the same moment)?
  select id into v_cv_id from cv_documents where drive_file_id = v_file_id and content_key = v_key;
  if found then
    return jsonb_build_object('outcome', 'already_processed', 'message', 'Already in the database',
                              'file_name', v_file_name, 'file_url', f->>'file_url', 'cv_id', v_cv_id, 'flags', '[]'::jsonb);
  end if;

  -- ===== A. Problem files: record them so a human sees them ==========
  if v_kind = 'flagged' then
    v_status := coalesce(p->>'status', 'error');
    if v_status not in ('unreadable', 'unsupported', 'not_a_cv', 'error') then v_status := 'error'; end if;
    v_message := coalesce(nullif(p->>'reason', ''), 'No reason given');
    insert into cv_documents (drive_file_id, content_key, file_name, file_url, mime_type, size_bytes,
                              status, is_current, status_reason, extraction_method, text_content)
    values (v_file_id, v_key, v_file_name, f->>'file_url', f->>'mime_type', (f->>'size_bytes')::bigint,
            v_status, false, v_message, p->>'extraction_method', nullif(p->>'text_content', ''))
    returning id into v_cv_id;
    insert into activity_log (event, file_name, cv_id, details)
    values (v_status, v_file_name, v_cv_id, jsonb_build_object('reason', v_message));
    return jsonb_build_object('outcome', v_status, 'message', v_message, 'file_name', v_file_name,
                              'file_url', f->>'file_url', 'cv_id', v_cv_id, 'flags', '[]'::jsonb);
  end if;

  if v_kind is distinct from 'extracted' then
    raise exception 'ingest_cv: unknown payload kind "%"', v_kind;
  end if;

  -- ===== B. Who is this? =============================================
  v_name       := nullif(trim(p->'identity'->>'full_name'), '');
  v_name_key   := coalesce(nullif(p->'identity'->>'name_key', ''), lower(coalesce(v_name, '')));
  v_emails     := array(select distinct lower(trim(x)) from jsonb_array_elements_text(coalesce(p->'identity'->'emails', '[]')) x where trim(x) <> '');
  v_phones     := array(select distinct trim(x)        from jsonb_array_elements_text(coalesce(p->'identity'->'phones', '[]')) x where trim(x) <> '');
  v_phone_keys := array(select distinct x              from jsonb_array_elements_text(coalesce(p->'identity'->'phone_keys', '[]')) x where x <> '');
  v_languages  := array(select distinct lower(x)       from jsonb_array_elements_text(coalesce(p->'languages', '[]')) x where x <> '');
  v_linkedin   := nullif(p->'identity'->>'linkedin', '');
  v_new_date   := nullif(p->>'cv_latest_date', '')::date;
  v_fp         := nullif(p->>'content_fingerprint', '');
  v_flags      := array(select distinct x from jsonb_array_elements_text(coalesce(p->'flags', '[]')) x);

  if v_name is null then
    raise exception 'ingest_cv: extracted CV has no name (%).', v_file_name;
  end if;

  -- 1) same email
  if cardinality(v_emails) > 0 then
    select * into v_cand from candidates where emails && v_emails order by created_at limit 1;
    v_found := found;
  end if;
  -- 2) same LinkedIn profile
  if not v_found and v_linkedin is not null then
    select * into v_cand from candidates where linkedin = v_linkedin order by created_at limit 1;
    v_found := found;
  end if;
  -- 3) same phone AND same first name (phone alone could be a typo or a shared office line).
  --    "Same phone" allows a missing country code: 3456789 matches 9613456789, but not 201023456789.
  if not v_found and cardinality(v_phone_keys) > 0 then
    select c.* into v_cand from candidates c
     where split_part(c.name_key, ' ', 1) = split_part(v_name_key, ' ', 1)
       and exists (select 1 from unnest(c.phone_keys) a, unnest(v_phone_keys) b
                    where a = b
                       or (length(a) - length(b) between 1 and 3 and length(b) >= 7 and right(a, length(b)) = b)
                       or (length(b) - length(a) between 1 and 3 and length(a) >= 7 and right(b, length(a)) = a))
     order by c.created_at limit 1;
    v_found := found;
  end if;

  -- ===== C. Known person: is this CV newer, older, or the same? =======
  if v_found then
    select * into v_cur from cv_documents where id = v_cand.current_cv_id;
    v_old_file := v_cur.file_name;

    if v_new_date is not null and v_cur.cv_latest_date is not null and v_new_date > v_cur.cv_latest_date then
      v_outcome := 'updated';
    elsif v_new_date is not null and v_cur.cv_latest_date is not null and v_new_date < v_cur.cv_latest_date then
      v_outcome := 'older_version';
    elsif v_fp is not null and v_fp = v_cur.content_fingerprint then
      v_outcome := 'duplicate';
    else
      -- Same dates (or no dates) but different content: keep the newest upload, ask a human to glance at it
      v_outcome := 'updated';
      v_flags := array_append(v_flags, 'check_which_is_newer');
    end if;

    if v_outcome = 'updated' then
      insert into cv_documents (candidate_id, drive_file_id, content_key, file_name, file_url, mime_type, size_bytes,
                                status, is_current, flags, extraction_method, text_content, profile,
                                cv_latest_date, content_fingerprint)
      values (v_cand.id, v_file_id, v_key, v_file_name, f->>'file_url', f->>'mime_type', (f->>'size_bytes')::bigint,
              'indexed', false, v_flags, p->>'extraction_method', p->>'text_content', p->'profile',
              v_new_date, v_fp)
      returning id into v_cv_id;
      update cv_documents set is_current = false, status = 'superseded', replaced_by = v_cv_id,
                              status_reason = format('Replaced by %s', v_file_name), updated_at = now()
       where candidate_id = v_cand.id and is_current;
      update cv_documents set is_current = true where id = v_cv_id;

      update candidates set
        full_name        = v_name,
        name_key         = v_name_key,
        emails           = array(select distinct unnest(emails || v_emails)),
        phones           = array(select distinct unnest(phones || v_phones)),
        phone_keys       = array(select distinct unnest(phone_keys || v_phone_keys)),
        linkedin         = coalesce(v_linkedin, linkedin),
        location         = coalesce(nullif(p->>'location', ''), location),
        timezone         = coalesce(nullif(p->>'timezone', ''), timezone),
        headline         = coalesce(nullif(p->>'headline', ''), headline),
        summary          = coalesce(nullif(p->>'summary', ''), summary),
        languages        = case when cardinality(v_languages) > 0 then v_languages else languages end,
        language_details = case when cardinality(v_languages) > 0 then coalesce(p->'language_details', '[]') else language_details end,
        total_years      = coalesce((p->>'total_years')::numeric, total_years),
        current_cv_id    = v_cv_id,
        updated_at       = now()
       where id = v_cand.id;

      delete from candidate_skills where candidate_id = v_cand.id;
      insert into candidate_skills (candidate_id, cv_id, skill, label, years, years_from_jobs, years_stated, evidence)
      select v_cand.id, v_cv_id, s.skill, s.label, s.years, s.years_from_jobs, s.years_stated, s.evidence
        from jsonb_to_recordset(coalesce(p->'skills', '[]')) as s(skill text, label text, years numeric,
                                years_from_jobs numeric, years_stated numeric, evidence text)
       where coalesce(s.skill, '') <> ''
      on conflict (candidate_id, skill) do nothing;

      v_message := format('Updated CV for %s. It replaces %s.', v_name, coalesce(v_old_file, 'the old one'));
      if 'check_which_is_newer' = any(v_flags) then
        v_message := v_message || ' Both CVs have the same dates, so the newest upload was kept. Please check it is the right one.';
      end if;

    else
      -- duplicate or older_version: keep the file on record, but not as the active CV
      insert into cv_documents (candidate_id, drive_file_id, content_key, file_name, file_url, mime_type, size_bytes,
                                status, is_current, flags, status_reason, extraction_method, text_content, profile,
                                cv_latest_date, content_fingerprint, duplicate_of, replaced_by)
      values (v_cand.id, v_file_id, v_key, v_file_name, f->>'file_url', f->>'mime_type', (f->>'size_bytes')::bigint,
              case v_outcome when 'duplicate' then 'duplicate' else 'superseded' end,
              false, v_flags,
              case v_outcome when 'duplicate' then format('Same CV as %s', v_cur.file_name)
                             else format('Older than %s', v_cur.file_name) end,
              p->>'extraction_method', p->>'text_content', p->'profile', v_new_date, v_fp,
              case v_outcome when 'duplicate' then v_cur.id end,
              case v_outcome when 'older_version' then v_cur.id end)
      returning id into v_cv_id;

      -- an extra email or phone on the copy still helps us recognise the person next time
      update candidates set
        emails     = array(select distinct unnest(emails || v_emails)),
        phones     = array(select distinct unnest(phones || v_phones)),
        phone_keys = array(select distinct unnest(phone_keys || v_phone_keys)),
        linkedin   = coalesce(linkedin, v_linkedin),
        updated_at = now()
       where id = v_cand.id;

      v_message := case v_outcome
        when 'duplicate' then format('Same CV as %s (%s). Kept the original.', v_cur.file_name, v_cand.full_name)
        else format('Older CV of %s. The newer one (%s) stays active.', v_cand.full_name, v_cur.file_name) end;
    end if;

    insert into activity_log (event, file_name, cv_id, candidate_id, details)
    values (v_outcome, v_file_name, v_cv_id, v_cand.id,
            jsonb_build_object('compared_with', v_old_file, 'new_date', v_new_date, 'old_date', v_cur.cv_latest_date));

    return jsonb_build_object('outcome', v_outcome, 'message', v_message, 'file_name', v_file_name,
                              'file_url', f->>'file_url', 'cv_id', v_cv_id, 'candidate_id', v_cand.id,
                              'candidate_name', case when v_outcome = 'updated' then v_name else v_cand.full_name end,
                              'flags', to_jsonb(v_flags));
  end if;

  -- ===== D. New person =================================================
  select * into v_twin from candidates where name_key = v_name_key order by created_at limit 1;
  v_has_twin := found;
  if v_has_twin then
    v_flags := array_append(v_flags, 'possible_duplicate');
  end if;

  insert into candidates (full_name, name_key, emails, phones, phone_keys, linkedin, location, timezone, headline,
                          summary, languages, language_details, total_years, possible_duplicate_of)
  values (v_name, v_name_key, v_emails, v_phones, v_phone_keys, v_linkedin,
          nullif(p->>'location', ''), nullif(p->>'timezone', ''), nullif(p->>'headline', ''), nullif(p->>'summary', ''),
          v_languages, coalesce(p->'language_details', '[]'), (p->>'total_years')::numeric,
          case when v_has_twin then v_twin.id end)
  returning * into v_cand;

  insert into cv_documents (candidate_id, drive_file_id, content_key, file_name, file_url, mime_type, size_bytes,
                            status, is_current, flags, extraction_method, text_content, profile,
                            cv_latest_date, content_fingerprint)
  values (v_cand.id, v_file_id, v_key, v_file_name, f->>'file_url', f->>'mime_type', (f->>'size_bytes')::bigint,
          'indexed', true, v_flags, p->>'extraction_method', p->>'text_content', p->'profile',
          v_new_date, v_fp)
  returning id into v_cv_id;

  update candidates set current_cv_id = v_cv_id where id = v_cand.id;

  insert into candidate_skills (candidate_id, cv_id, skill, label, years, years_from_jobs, years_stated, evidence)
  select v_cand.id, v_cv_id, s.skill, s.label, s.years, s.years_from_jobs, s.years_stated, s.evidence
    from jsonb_to_recordset(coalesce(p->'skills', '[]')) as s(skill text, label text, years numeric,
                            years_from_jobs numeric, years_stated numeric, evidence text)
   where coalesce(s.skill, '') <> ''
  on conflict (candidate_id, skill) do nothing;

  if v_has_twin then
    v_outcome := 'possible_duplicate';
    v_message := format('New candidate %s, but someone with the same name is already saved (from %s). '
                        || 'Contact details differ, so they were kept apart. Please check if it is the same person.',
                        v_name, coalesce((select file_name from cv_documents where id = v_twin.current_cv_id), 'another CV'));
  else
    v_outcome := 'new_candidate';
    v_message := format('New candidate: %s', v_name);
  end if;

  insert into activity_log (event, file_name, cv_id, candidate_id, details)
  values (v_outcome, v_file_name, v_cv_id, v_cand.id, jsonb_build_object('flags', v_flags));

  return jsonb_build_object('outcome', v_outcome, 'message', v_message, 'file_name', v_file_name,
                            'file_url', f->>'file_url', 'cv_id', v_cv_id, 'candidate_id', v_cand.id,
                            'candidate_name', v_name, 'flags', to_jsonb(v_flags));
end $$;

-- ---------------------------------------------------------------------
-- 7. Views for the portal and for later workflows
-- ---------------------------------------------------------------------
create or replace view cv_library with (security_invoker = true) as
select d.created_at       as received_at,
       d.file_name,
       d.file_url,
       d.status,
       d.flags,
       d.status_reason,
       d.is_current,
       c.full_name         as candidate_name,
       d.extraction_method,
       dup.file_name       as duplicate_of_file,
       rep.file_name       as replaced_by_file,
       d.id                as cv_id,
       d.candidate_id
  from cv_documents d
  left join candidates   c   on c.id   = d.candidate_id
  left join cv_documents dup on dup.id = d.duplicate_of
  left join cv_documents rep on rep.id = d.replaced_by;

create or replace view searchable_candidates with (security_invoker = true) as
select c.id            as candidate_id,
       c.full_name,
       c.headline,
       c.emails,
       c.phones,
       c.location,
       c.timezone,
       c.languages,
       c.total_years,
       d.id            as cv_id,
       d.file_name     as cv_file_name,
       d.file_url      as cv_file_url,
       d.flags         as cv_flags,
       d.text_content,
       d.search_text,
       coalesce((select jsonb_agg(jsonb_build_object('skill', s.skill, 'label', s.label, 'years', s.years)
                                  order by s.years desc nulls last)
                   from candidate_skills s where s.candidate_id = c.id), '[]'::jsonb) as skills
  from candidates c
  join cv_documents d on d.id = c.current_cv_id and d.is_current;

-- ---------------------------------------------------------------------
-- 8. Security: n8n connects as the database owner, so it is not affected.
--    These lines stop anyone with your public Supabase "anon" key from
--    reading or changing candidate data through the REST API.
-- ---------------------------------------------------------------------
alter table candidates       enable row level security;
alter table cv_documents     enable row level security;
alter table candidate_skills enable row level security;
alter table activity_log     enable row level security;

revoke execute on function cv_check_file(jsonb) from public;
revoke execute on function ingest_cv(jsonb)     from public;

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on cv_library, searchable_candidates from %I', r);
      execute format('revoke execute on function cv_check_file(jsonb), ingest_cv(jsonb) from %I', r);
    end if;
  end loop;
end $$;

select 'Workflow 1 database is ready ✅' as status,
       (select count(*) from candidates)   as candidates,
       (select count(*) from cv_documents) as cv_files;
