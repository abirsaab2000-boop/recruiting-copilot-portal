# Recruiting Copilot

An AI recruiting assistant for a remote-staffing agency (fictional: *Cedar Remote Talent*). Built with **n8n**, **Supabase**, **Gemini**, **Slack** and **GoHighLevel**, with a recruiter portal built with **Claude Code**.

**Live portal:** https://abirsaab2000-boop.github.io/recruiting-copilot-portal/ (sign-in required)

> **Test data only.** Every candidate, client, email address and phone number in this project is invented.

## What it does

```
CVs dropped in Google Drive ──▶ WF1  read every CV (PDF, Word, scans) ──▶ searchable candidate database
                                     duplicates merged, newer CVs replace older ones, problems flagged

Client call transcript ──▶ WF4  job description (only what the client said) ──▶ Slack: Approve / Decline
                                                                                    │ approved
                                                                                    ▼
                           WF5a shortlist (top 5 from WF2) ──▶ Slack: Approve / Decline for EACH candidate
                                                                                    │ approved
                                                                                    ▼
                           WF5b GoHighLevel pipeline + email outreach that stops on reply  (test mode, see Status)

Recruiter asks in Slack ("who has 3+ years of GHL and speaks Arabic?") ──▶ WF7 ──▶ WF2 ──▶ top 5, each with score, reason and CV

WF3 asks the 10 test questions ──▶ marks every answer ──▶ score out of 10 (portal + Slack)
```

## The rules, and how each is enforced

| Rule | How |
|---|---|
| **Nothing reaches a candidate or client before Approve** | Job descriptions are saved as *waiting for approval*. A shortlist only starts after the job description is approved. A candidate only goes to GoHighLevel after their own Approve click, and the database function `mark_sent_to_ghl` refuses anyone who isn't approved. A decision can only be made once. |
| **The bot never invents a candidate** | Gemini only scores people the database search returned. Its answer must use their exact IDs, and the code throws away any other ID. Names and CV links always come from the database, never from the AI. `save_shortlist` drops anyone who doesn't exist. |
| **Every recommendation names its CV** | Each candidate in a Slack answer, shortlist and portal page carries the CV file it came from, with a link. The test runner marks an answer wrong if a CV is missing. |
| **Unreadable CVs are flagged, never silently skipped** | Every file gets a row in the CV library with what happened to it. Scanned PDFs and photos are read as images. Anything a person should check (unreadable, unsupported, read from a scan, same name as someone else) is listed under "Needs a human" in Slack and in the portal's CV library. |

## Workflows (`n8n/`)

| File | Trigger | What it does |
|---|---|---|
| `WF1a_cv_intake.json` | New file in the CV folder, or run on the whole folder | Lists the files, processes each one with WF1b, then posts a summary to Slack |
| `WF1b_process_one_cv.json` | Called by WF1a | Detects the file type → reads text (PDF/Word) or sends the scan/photo to Gemini → checks and cleans the result → `ingest_cv` (new / duplicate / updated / flagged) |
| `WF2_search_candidates.json` | Called by WF7, WF3, WF5a | Question → filters (Gemini) → hard requirements in SQL → scoring (Gemini, fixed scorecard) → top 5, or an honest "no match" with the closest people |
| `WF3_test_runner.json` | Manual | Asks the 10 test questions one at a time, marks each answer, saves the run and posts the score |
| `WF4_job_descriptions.json` | Form: paste a call transcript | Gemini writes the job description. The code checks each requirement against a real line of the transcript and flags anything not confirmed. Then Slack approval, and an approved role starts WF5a |
| `WF5a_shortlist_a_role.json` | Called by WF4 | Searches for the role's must-haves (nice-to-haves add points), saves the shortlist, and asks about each candidate |
| `WF5b_approve_one_candidate.json` | Called by WF5a, once per candidate | Slack Approve / Decline → saves the decision → approved candidates go to GoHighLevel (test mode) |
| `WF7_slack_qa_bot.json` | Every minute | Reads new questions in #ask-copilot and answers in the thread |

Importing into another n8n instance: re-select the credentials (Postgres, Gemini, Slack, Google Drive) and the sub-workflows in each "Execute Workflow" node, set your CV folder in WF1a, and publish the sub-workflows first (WF5b → WF5a → WF4).

## Database (`supabase/`)

Run these in the Supabase SQL Editor, in this order:

1. `wf1_database_setup.sql`: candidates, CV files, skills, and the duplicate / updated-CV rules
2. `wf2_search_setup.sql`: search and the search log
3. `wf3_test_setup.sql`: the 10 test questions and test runs
4. `wf4_roles_setup.sql`: roles (job descriptions) and approvals
5. `wf5_shortlist_setup.sql`: shortlists, candidate decisions and pipeline stages
6. `portal_setup.sql`: the read-only views the portal uses

All logic that must never be skipped (deduplication, "approved only", "once only") lives in these database functions, not in the workflows.

## Test data and results (`test-data/`)

- **60 CVs for 55 people** (PDF and Word, 7 layouts), deliberately messy:
  - 1 scanned CV with no text layer;
  - 3 people sent their CV twice;
  - 2 people sent an updated CV;
  - 2 different people share the same name;
  - skills are written several ways ("GHL", "HighLevel", "Go High Level").
- **5 client call transcripts**, each with details left unclear for the job description to flag.
- **`answer_key.xlsx`**: what should happen to every file, plus the 10 test questions with their right answers and the "close but wrong" people.
- **Latest score: 10/10.** The questions cover reading the scan, using only the newest CV, keeping duplicates once, telling the two same-name people apart, and saying "nobody" when nobody fits.

## Recruiter portal (this site)

| Page | What you see |
|---|---|
| **Today** | Candidates waiting for your decision, the latest test score, the pipeline at a glance, CV library totals, latest searches |
| **Roles** | Every job description, what the client left unclear, and its shortlist (score, two-line reason, CV, decision) |
| **Pipeline** | Every shortlisted candidate by stage |
| **CV library** | Every file received and what happened to it |
| **Copilot test** | The 10 questions, right answers, the copilot's answers and the score for every run |

It is a static site (`index.html`, `assets/`) with no build step. It signs in with Supabase Auth and reads only the `portal_*` views. Public sign-ups are off; logins are created in Supabase → Authentication → Users. The key in `config.js` is Supabase's public (publishable) key: on its own it can't read any data.

To run it on your computer: `python3 -m http.server 8000` in this folder, then open http://localhost:8000.

## Status

| Part | Status |
|---|---|
| CV search, Slack bot, test runner, job descriptions, shortlists and approvals, portal | Working |
| GoHighLevel pipeline + outreach that stops on reply | **Test mode.** The sub-account login used has no API access yet (no Private Integrations). Approved candidates are tracked in the database and portal as "Contacted, test mode". Going live means replacing one node in WF5b with two GoHighLevel calls (create contact with tag `copilot-outreach`, create opportunity). The outreach itself is a GoHighLevel workflow with *Stop on response* on, and email only. |
| Reply handling (WF6) | Waits for GoHighLevel API access: it will read stage changes from GoHighLevel and update the pipeline. |
| CV intake from Google Drive | Built and tested with a stand-in download step; waits for the Google login on the n8n server. |
| Slack bot | Checks the channel every minute, because Slack's event messages don't reach this n8n server. |
| AI | Gemini free tier (fine for fake data only), with retries for its busy periods. |
