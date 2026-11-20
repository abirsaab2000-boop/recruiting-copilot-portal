-- =====================================================================
--  AI Recruiting Copilot · GoHighLevel go-live · database update
--
--  HOW TO USE: Supabase → SQL Editor → New query → paste this whole file → Run.
--  Run it AFTER wf5_shortlist_setup.sql. Safe to run again later.
--
--  WHAT IT CHANGES
--    shortlist.ghl_email   the email address the outreach was sent to
--                          (in demo mode that's your own inbox, not the fake CV address)
--    mark_sent_to_ghl()    now also remembers that address
--    ghl_reply()           NEW: when a candidate replies in GoHighLevel, n8n calls this
--                          to move them to "Replied" (portal + database)
-- =====================================================================

alter table shortlist add column if not exists ghl_email text;
create index if not exists shortlist_ghl_email_idx on shortlist (lower(ghl_email));

-- ---------------------------------------------------------------------
-- mark_sent_to_ghl(p): p = {shortlist_id, mode: test|live, ghl_email, ghl_contact_id, ghl_opportunity_id}
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
                       ghl_email = coalesce(nullif(lower(trim(p->>'ghl_email')), ''), ghl_email),
                       ghl_contact_id = coalesce(nullif(p->>'ghl_contact_id', ''), ghl_contact_id),
                       ghl_opportunity_id = coalesce(nullif(p->>'ghl_opportunity_id', ''), ghl_opportunity_id),
                       updated_at = now()
   where id = v_s.id
  returning * into v_s;
  select full_name into v_name from candidates where id = v_s.candidate_id;

  return jsonb_build_object('shortlist_id', v_s.id, 'stage', v_s.stage, 'mode', v_mode,
    'message', case v_mode
      when 'live' then format('📬 *%s* was sent to GoHighLevel (outreach to %s). The Copilot · Candidate outreach workflow adds them to Candidates → Contacted and starts the emails, which stop as soon as they reply. Check its Execution logs if they don''t appear.', v_name, coalesce(v_s.ghl_email, 'their email'))
      else format('🧪 TEST MODE: *%s* is now in stage Contacted here. In live mode they would be added to GoHighLevel and the outreach emails would start. Nothing was sent.', v_name) end);
end $$;

-- ---------------------------------------------------------------------
-- ghl_reply(p): p = {email}  ← sent by GoHighLevel when a candidate replies
--   Moves the most recent approved candidate with that outreach address to "replied".
--   A later stage (interview, hired…) is never moved back.
-- ---------------------------------------------------------------------
create or replace function ghl_reply(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_s     shortlist%rowtype;
  v_name  text;
  v_role  roles%rowtype;
begin
  if v_email = '' then
    return jsonb_build_object('changed', false, 'message', '⚠️ GoHighLevel sent a reply notice without an email address.');
  end if;

  select * into v_s from shortlist
   where lower(ghl_email) = v_email and status = 'approved'
   order by sent_to_ghl_at desc nulls last limit 1;
  if not found then
    return jsonb_build_object('changed', false,
      'message', format('⚠️ GoHighLevel says %s replied, but no approved candidate was sent outreach at that address.', v_email));
  end if;

  select full_name into v_name from candidates where id = v_s.candidate_id;
  select * into v_role from roles where id = v_s.role_id;

  if v_s.stage is not null and v_s.stage <> 'contacted' then
    return jsonb_build_object('changed', false, 'shortlist_id', v_s.id, 'stage', v_s.stage,
      'message', format('💬 *%s* replied again (already at stage %s). Nothing changed.', v_name, replace(v_s.stage, '_', ' ')));
  end if;

  update shortlist set stage = 'replied', updated_at = now() where id = v_s.id returning * into v_s;

  return jsonb_build_object('changed', true, 'shortlist_id', v_s.id, 'stage', v_s.stage, 'name', v_name,
    'message', format('💬 *%s* replied about %s (%s). The email sequence stopped, and they are now in stage Replied.',
                      v_name, v_role.role_title, v_role.client_company));
end $$;

-- the portal's view gains the new column
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

-- security: same rules as the other functions
revoke execute on function mark_sent_to_ghl(jsonb) from public;
revoke execute on function ghl_reply(jsonb)        from public;
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function mark_sent_to_ghl(jsonb), ghl_reply(jsonb) from %I', r);
      execute format('revoke all on public.portal_shortlist from %I', r);
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.portal_shortlist to authenticated';
  end if;
end $$;

select 'GoHighLevel go-live update is ready ✅' as status;
