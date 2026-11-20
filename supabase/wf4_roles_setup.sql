-- =====================================================================
--  AI Recruiting Copilot · Workflow 4 (Job descriptions) · database setup
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf1_database_setup.sql. Safe to run again later.
--
--  WHAT IT ADDS
--    roles           one row per client role: the call transcript, the job
--                    description written from it, what was left unclear,
--                    and its status (waiting for approval → approved / rejected)
--    save_role()     saves a new job description as "waiting for approval"
--    decide_role()   records Approve or Reject from Slack
--    open_roles      view: approved roles (for the portal and the shortlist)
-- =====================================================================

create table if not exists roles (
  id               bigint generated always as identity primary key,
  created_at       timestamptz not null default now(),
  client_company   text not null,
  client_contact   text,
  role_title       text not null,
  hires            int,
  transcript       text not null,          -- the call, exactly as pasted
  jd               jsonb not null,         -- the job description, field by field
  jd_text          text not null,          -- the job description as one readable text
  open_questions   jsonb not null default '[]',   -- what the client left unclear: [{topic, note}]
  search_question  text,                   -- plain-English question used to find the shortlist
  status           text not null default 'pending_approval'
                   check (status in ('pending_approval', 'approved', 'rejected', 'filled', 'closed')),
  decided_at       timestamptz,
  decided_by       text,
  updated_at       timestamptz not null default now()
);
create index if not exists roles_status_idx on roles (status, created_at desc);

-- ---------------------------------------------------------------------
-- save_role(p): saves a new job description, waiting for approval
-- ---------------------------------------------------------------------
create or replace function save_role(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_id bigint;
begin
  if coalesce(trim(p->>'transcript'), '') = '' then raise exception 'save_role: transcript is empty'; end if;
  if coalesce(trim(p->>'role_title'), '') = '' then raise exception 'save_role: role_title is empty'; end if;

  insert into roles (client_company, client_contact, role_title, hires, transcript, jd, jd_text, open_questions, search_question)
  values (coalesce(nullif(trim(p->>'client_company'), ''), 'Unknown client'),
          nullif(trim(p->>'client_contact'), ''),
          p->>'role_title',
          (p->>'hires')::int,
          p->>'transcript',
          p->'jd',
          p->>'jd_text',
          coalesce(p->'open_questions', '[]'::jsonb),
          nullif(trim(p->>'search_question'), ''))
  returning id into v_id;

  return jsonb_build_object('role_id', v_id, 'status', 'pending_approval',
                            'role_title', p->>'role_title', 'client_company', p->>'client_company');
end $$;

-- ---------------------------------------------------------------------
-- decide_role(p): Approve or Reject  →  p = {role_id, decision: approved|rejected, decided_by}
--   Only a role that is still waiting can be decided (a second click changes nothing).
-- ---------------------------------------------------------------------
create or replace function decide_role(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_role roles%rowtype;
  v_decision text := p->>'decision';
begin
  if v_decision not in ('approved', 'rejected') then
    raise exception 'decide_role: decision must be approved or rejected, got %', v_decision;
  end if;

  update roles set status = v_decision, decided_at = now(), updated_at = now(),
                   decided_by = coalesce(nullif(p->>'decided_by', ''), 'slack')
   where id = (p->>'role_id')::bigint and status = 'pending_approval'
  returning * into v_role;

  if not found then
    select * into v_role from roles where id = (p->>'role_id')::bigint;
    if not found then raise exception 'decide_role: role % not found', p->>'role_id'; end if;
    return jsonb_build_object('role_id', v_role.id, 'status', v_role.status, 'changed', false,
      'message', format('Role #%s (%s, %s) was already %s. Nothing changed.',
                        v_role.id, v_role.role_title, v_role.client_company, replace(v_role.status, '_', ' ')));
  end if;

  return jsonb_build_object('role_id', v_role.id, 'status', v_role.status, 'changed', true,
    'role_title', v_role.role_title, 'client_company', v_role.client_company,
    'search_question', v_role.search_question,
    'message', case v_decision
      when 'approved' then format('✅ *Approved:* %s for %s (role #%s). It is now an open role, ready for a shortlist.',
                                  v_role.role_title, v_role.client_company, v_role.id)
      else format('❌ *Rejected:* %s for %s (role #%s). Nothing was shared. Fix the details with the client and submit the call again.',
                  v_role.role_title, v_role.client_company, v_role.id) end);
end $$;

-- ---------------------------------------------------------------------
-- open_roles: approved roles (for the portal and the shortlist workflow)
-- ---------------------------------------------------------------------
create or replace view open_roles as
  select id as role_id, client_company, client_contact, role_title, hires, search_question,
         open_questions, jd_text, decided_at as approved_at
    from roles where status = 'approved' order by decided_at desc;

-- ---------------------------------------------------------------------
-- Security: keep these away from the public "anon" key
-- ---------------------------------------------------------------------
alter table roles enable row level security;
revoke execute on function save_role(jsonb)   from public;
revoke execute on function decide_role(jsonb) from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function save_role(jsonb), decide_role(jsonb) from %I', r);
      execute format('revoke all on open_roles from %I', r);
    end if;
  end loop;
end $$;

select 'Workflow 4 database is ready ✅' as status, (select count(*) from roles) as roles;
