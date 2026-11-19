# Recruiting Copilot · Recruiter portal

The recruiter-facing portal for **Recruiting Copilot**, an AI recruiting assistant for a remote-staffing agency (fictional: *Cedar Remote Talent*). It was built with Claude Code and is part of a project that also includes n8n workflows, a Slack bot and GoHighLevel.

> **Test data only.** Every candidate, client, email address and phone number in this project is invented.

## What it shows

| Page | What you see |
|---|---|
| **Today** | Candidates waiting for your decision, the copilot's latest test score, the pipeline at a glance, CV library totals and the latest searches. |
| **Roles** | Every job description written from a client call, with what the client left unclear and the shortlist the copilot found. Each candidate has a score, a two-line reason, the CV it came from and your decision. |
| **Pipeline** | Every shortlisted candidate by stage: waiting for your decision, contacted, replied, interview, submitted to client, hired, not a fit, or declined. |
| **CV library** | Every CV file received and what happened to it: searchable, duplicate kept once, identical copy skipped, replaced by a newer CV, read from a scan, or flagged. Nothing is skipped silently. |
| **Copilot test** | Ten questions with known right answers, the copilot's answer to each, why each one is tricky, and the score out of 10 for every test run. |

## How it works

```
Browser (this site)  ── sign in ──▶  Supabase Auth
        │
        └── read-only ──▶  Supabase REST API  ──▶  portal_* views  ──▶  tables filled by the n8n workflows
```

- **A plain static site**: `index.html`, `assets/app.js` and `assets/styles.css`, with no build step and no libraries. It can be hosted anywhere, including GitHub Pages.
- **Signing in is required.** It uses Supabase Auth with email and password. Public sign-ups are turned off, so only logins created by the agency work.
- **Read-only, and only what the portal needs.** Signed-in users can read the `portal_*` views (see `supabase/portal_setup.sql`) and nothing else. Row-level security keeps the underlying tables closed. The views leave out phone numbers and full CV text.
- The Supabase URL and the public ("anon" or "publishable") key in `config.js` are designed to be public. On their own they can't read any data.

## Set up

1. **Database:** in the Supabase SQL Editor, run `supabase/portal_setup.sql`. Run it after the workflow setup files (`wf1` to `wf5`).
2. **Turn off public sign-ups:** Supabase → Authentication → Sign In / Providers → turn off **Allow new users to sign up**.
3. **Create a portal login:** Supabase → Authentication → Users → **Add user** → **Create new user**. Enter an email and password and tick **Auto Confirm User**.
4. **Connect the site:** in `config.js`, enter your project URL and anon/publishable key (Supabase → Project Settings → API).
5. **Publish:** GitHub → this repo → Settings → Pages → *Deploy from a branch* → `main` / `(root)`.

## Run it on your computer

Any static file server works, for example `python3 -m http.server 8000` in this folder. Then open http://localhost:8000.
