-- =====================================================================
--  AI Recruiting Copilot · Workflow 5 (Shortlist + approval) · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf4_roles_setup.sql. Safe to run again later.
--
--  WHAT IT ADDS
--    shortlist           one row per candidate proposed for a role: score, reason,
--                        CV, your decision, and their pipeline stage
--    save_shortlist()    saves the copilot's top candidates for a role, and writes
--                        the Slack messages (one summary + one per candidate)
--    decide_candidate()  records Approve or Decline for one candidate
--    mark_sent_to_ghl()  records that a candidate went into GoHighLevel
--                        (or would have, in TEST mode) → stage "contacted"
--    set_stage()         moves a candidate to another pipeline stage (used by the
--                        GoHighLevel sync later)
--    pipeline_board      view: every approved candidate with their stage (for the portal)
--    role_shortlists     view: every role with its shortlist (for the portal)
-- =====================================================================

create table if not exists shortlist (
  id                  bigint generated always as identity primary key,
  role_id             bigint not null references roles(id) on delete cascade,
  candidate_id        uuid not null references candidates(id) on delete cascade,
  search_id           bigint,                       -- the search that found them (searches.id)
  rank                int,
  score               int,                          -- out of 100
  score_parts         jsonb,
  why_fit             text,
  gap_or_risk         text,
  cv_id               uuid,
  cv_file_name        text,
  cv_file_url         text,
  status              text not null default 'waiting_approval'
                      check (status in ('waiting_approval', 'approved', 'declined')),
  decided_at          timestamptz,
  decided_by          text,
  stage               text check (stage in ('contacted', 'replied', 'interview', 'submitted_to_client', 'hired', 'not_a_fit')),
  ghl_mode            text check (ghl_mode in ('test', 'live')),
  ghl_contact_id      text,
  ghl_opportunity_id  text,
  sent_to_ghl_at      timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (role_id, candidate_id)                    -- a person is on a role's shortlist once
);
create index if not exists shortlist_role_idx on shortlist (role_id, rank);

-- ---------------------------------------------------------------------
-- save_shortlist(p): p = {role_id, answer}  (answer = what the search workflow returned)
--   Only real candidates from the search are saved. Running it twice for the same
--   role adds nobody twice.
-- ---------------------------------------------------------------------
create or replace function save_shortlist(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_role     roles%rowtype;
  v_answer   jsonb := coalesce(p->'answer', '{}'::jsonb);
  v_c        jsonb;
  v_id       bigint;
  v_new      jsonb := '[]'::jsonb;
  v_total    int;
  v_i        int := 0;
  v_msg      text;
begin
  select * into v_role from roles where id = (p->>'role_id')::bigint;
  if not found then raise exception 'save_shortlist: role % not found', p->>'role_id'; end if;
  if v_role.status <> 'approved' then raise exception 'save_shortlist: role % is %, not approved', v_role.id, v_role.status; end if;

  for v_c in select * from jsonb_array_elements(coalesce(v_answer->'candidates', '[]'::jsonb)) loop
    -- only people who really exist in the database
    continue when not exists (select 1 from candidates where id = (v_c->>'candidate_id')::uuid);
    insert into shortlist (role_id, candidate_id, search_id, rank, score, score_parts, why_fit, gap_or_risk, cv_id, cv_file_name, cv_file_url)
    values (v_role.id, (v_c->>'candidate_id')::uuid, (v_answer->>'search_id')::bigint, (v_c->>'rank')::int, (v_c->>'score')::int,
            v_c->'score_parts', v_c->>'why_fit', v_c->>'gap_or_risk', nullif(v_c->>'cv_id', '')::uuid, v_c->>'cv_file_name', v_c->>'cv_file_url')
    on conflict (role_id, candidate_id) do nothing
    returning id into v_id;
    if v_id is not null then
      v_new := v_new || jsonb_build_object('shortlist_id', v_id, 'name', v_c->>'name', 'score', (v_c->>'score')::int,
                                           'why_fit', v_c->>'why_fit', 'gap_or_risk', v_c->>'gap_or_risk',
                                           'cv_file_name', v_c->>'cv_file_name', 'cv_file_url', v_c->>'cv_file_url');
    end if;
    v_id := null;
  end loop;

  v_total := jsonb_array_length(v_new);

  -- one Slack message per candidate, with the CV and the reason
  select coalesce(jsonb_agg(x.c || jsonb_build_object('slack_text', format(
           E'👤 *Candidate %s of %s for %s* · %s (role #%s)\n*%s* · %s/100\n✅ %s\n⚠️ %s\n📄 %s\nApprove to add them to GoHighLevel and start the email outreach. Nothing is sent if you decline.',
           x.n, v_total, v_role.role_title, v_role.client_company, v_role.id,
           x.c->>'name', x.c->>'score', coalesce(x.c->>'why_fit', ''), coalesce(x.c->>'gap_or_risk', ''),
           case when coalesce(x.c->>'cv_file_url', '') <> '' then format('<%s|%s>', x.c->>'cv_file_url', x.c->>'cv_file_name')
                else x.c->>'cv_file_name' end)) order by x.n), '[]'::jsonb)
    into v_new
    from (select c, row_number() over () as n from jsonb_array_elements(v_new) c) x;

  if v_total > 0 then
    v_msg := format(E'🔎 *Shortlist ready: %s* · %s (role #%s)\nSearch: _%s_\n%s candidate%s below, each with Approve / Decline. Nobody is contacted until you approve them.',
                    v_role.role_title, v_role.client_company, v_role.id, coalesce(v_answer->>'question', v_role.search_question),
                    v_total, case when v_total = 1 then '' else 's' end);
  elsif jsonb_array_length(coalesce(v_answer->'candidates', '[]'::jsonb)) > 0 then
    v_msg := format('🔎 *%s* · %s (role #%s): everyone the search found is already on this shortlist. Nothing new to approve.',
                    v_role.role_title, v_role.client_company, v_role.id);
  else
    v_msg := format(E'🔎 *No shortlist yet for %s* · %s (role #%s)\n%s',
                    v_role.role_title, v_role.client_company, v_role.id, coalesce(v_answer->>'message', 'The search found nobody.'));
  end if;

  return jsonb_build_object('role_id', v_role.id, 'role_title', v_role.role_title, 'client_company', v_role.client_company,
                            'search_status', v_answer->>'status', 'count', v_total, 'candidates', v_new, 'message', v_msg);
end $$;

-- ---------------------------------------------------------------------
-- decide_candidate(p): p = {shortlist_id, decision: approved|declined, decided_by}
--   A candidate can only be decided once. Returns what GoHighLevel needs.
-- ---------------------------------------------------------------------
create or replace function decide_candidate(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_s        shortlist%rowtype;
  v_c        candidates%rowtype;
  v_role     roles%rowtype;
  v_decision text := p->>'decision';
  v_first    text;
  v_last     text;
begin
  if v_decision not in ('approved', 'declined') then
    raise exception 'decide_candidate: decision must be approved or declined, got %', v_decision;
  end if;

  update shortlist set status = v_decision, decided_at = now(), updated_at = now(),
                       decided_by = coalesce(nullif(p->>'decided_by', ''), 'slack')
   where id = (p->>'shortlist_id')::bigint and status = 'waiting_approval'
  returning * into v_s;

  if not found then
    select * into v_s from shortlist where id = (p->>'shortlist_id')::bigint;
    if not found then raise exception 'decide_candidate: shortlist entry % not found', p->>'shortlist_id'; end if;
    select * into v_c from candidates where id = v_s.candidate_id;
    return jsonb_build_object('shortlist_id', v_s.id, 'status', v_s.status, 'changed', false,
      'message', format('%s was already %s for this role. Nothing changed.', v_c.full_name, v_s.status));
  end if;

  select * into v_c from candidates where id = v_s.candidate_id;
  select * into v_role from roles where id = v_s.role_id;
  v_first := split_part(v_c.full_name, ' ', 1);
  v_last  := nullif(trim(substr(v_c.full_name, length(v_first) + 1)), '');

  return jsonb_build_object(
    'shortlist_id', v_s.id, 'status', v_s.status, 'changed', true,
    'candidate_id', v_c.id, 'name', v_c.full_name, 'first_name', v_first, 'last_name', v_last,
    'email', v_c.emails[1],
    'role_id', v_role.id, 'role_title', v_role.role_title, 'client_company', v_role.client_company,
    'score', v_s.score, 'cv_file_name', v_s.cv_file_name, 'cv_file_url', v_s.cv_file_url,
    'message', case v_decision
      when 'approved' then format('✅ *%s* approved for %s (%s).', v_c.full_name, v_role.role_title, v_role.client_company)
      else format('❌ *%s* declined for %s (%s). Nothing was sent to them.', v_c.full_name, v_role.role_title, v_role.client_company) end);
end $$;

-- ---------------------------------------------------------------------
-- mark_sent_to_ghl(p): p = {shortlist_id, mode: test|live, ghl_contact_id, ghl_opportunity_id}
--   Only approved candidates can go to GoHighLevel. Stage becomes "contacted".
-- ---------------------------------------------------------------------
create or replace function mark_sent_to_ghl(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_s    shortlist%rowtype;
  v_name text;
  v_mode text := coalesce(nullif(p->>'mode', ''), 'test');
begin
  if v_mode not in ('test', 'live') then raise exception 'mark_sent_to_ghl: mode must be test or live'; end if;
  select * into v_s from shortlist where id = (p->>'shortlist_id')::bigint;
  if not found then raise exception 'mark_sent_to_ghl: shortlist entry % not found', p->>'shortlist_id'; end if;
  if v_s.status <> 'approved' then
    raise exception 'mark_sent_to_ghl: entry % is %, not approved. Nothing goes to GoHighLevel without approval.', v_s.id, v_s.status;
  end if;

  update shortlist set stage = coalesce(stage, 'contacted'), ghl_mode = v_mode, sent_to_ghl_at = coalesce(sent_to_ghl_at, now()),
                       ghl_contact_id = coalesce(nullif(p->>'ghl_contact_id', ''), ghl_contact_id),
                       ghl_opportunity_id = coalesce(nullif(p->>'ghl_opportunity_id', ''), ghl_opportunity_id),
                       updated_at = now()
   where id = v_s.id
  returning * into v_s;
  select full_name into v_name from candidates where id = v_s.candidate_id;

  return jsonb_build_object('shortlist_id', v_s.id, 'stage', v_s.stage, 'mode', v_mode,
    'message', case v_mode
      when 'live' then format('📬 *%s* is in GoHighLevel → Candidates → Contacted. The outreach emails have started and stop as soon as they reply.', v_name)
      else format('🧪 TEST MODE: *%s* is now in stage Contacted here. In live mode they would be added to GoHighLevel and the outreach emails would start. Nothing was sent.', v_name) end);
end $$;

-- ---------------------------------------------------------------------
-- set_stage(p): p = {shortlist_id | ghl_opportunity_id, stage}
-- ---------------------------------------------------------------------
create or replace function set_stage(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_s shortlist%rowtype;
begin
  update shortlist set stage = p->>'stage', updated_at = now()
   where status = 'approved'
     and ((p ? 'shortlist_id' and id = (p->>'shortlist_id')::bigint)
       or (p ? 'ghl_opportunity_id' and ghl_opportunity_id = p->>'ghl_opportunity_id'))
  returning * into v_s;
  if not found then return jsonb_build_object('changed', false); end if;
  return jsonb_build_object('changed', true, 'shortlist_id', v_s.id, 'stage', v_s.stage);
end $$;

-- ---------------------------------------------------------------------
-- Views for the portal
-- ---------------------------------------------------------------------
create or replace view role_shortlists as
  select r.id as role_id, r.role_title, r.client_company, r.status as role_status, r.search_question,
         s.id as shortlist_id, s.rank, s.score, s.why_fit, s.gap_or_risk, s.cv_file_name, s.cv_file_url,
         s.status as decision, s.stage, c.full_name, c.location
    from roles r
    left join shortlist s on s.role_id = r.id
    left join candidates c on c.id = s.candidate_id;

create or replace view pipeline_board as
  select s.stage, c.full_name, c.location, r.role_title, r.client_company, s.score, s.cv_file_name, s.cv_file_url,
         s.ghl_mode, s.sent_to_ghl_at, s.id as shortlist_id, r.id as role_id
    from shortlist s
    join candidates c on c.id = s.candidate_id
    join roles r on r.id = s.role_id
   where s.status = 'approved';

-- ---------------------------------------------------------------------
-- Security: keep these away from the public "anon" key
-- ---------------------------------------------------------------------
alter table shortlist enable row level security;
revoke execute on function save_shortlist(jsonb)    from public;
revoke execute on function decide_candidate(jsonb)  from public;
revoke execute on function mark_sent_to_ghl(jsonb)  from public;
revoke execute on function set_stage(jsonb)         from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function save_shortlist(jsonb), decide_candidate(jsonb), mark_sent_to_ghl(jsonb), set_stage(jsonb) from %I', r);
      execute format('revoke all on role_shortlists, pipeline_board from %I', r);
    end if;
  end loop;
end $$;

select 'Workflow 5 database is ready ✅' as status, (select count(*) from shortlist) as shortlisted;
