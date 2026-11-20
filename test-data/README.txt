RECRUITING COPILOT · TEST DATASET
FICTIONAL TEST DATA. Every person, company, email and phone number is invented.
Emails all end in example.com / example.net / example.org, which can never receive mail.

WHAT'S HERE
  CVs/                    60 CV files (PDF + Word) for 55 people, 11 per role
  transcripts/            5 client call transcripts (one per open role)
  answer_key.xlsx         right answers for the 10 test questions + what every file is
  wf_test_data_60.sql     what Workflow 1 saves after reading all 60 CVs

WHAT TO DO WITH EACH
  1. Now (no Google Drive needed):
     Supabase → SQL Editor → New query → paste wf_test_data_60.sql → Run.
     It replaces the 6 test candidates with these 55. Then ask the Slack bot
     the questions in answer_key.xlsx → "Test questions".

  2. When Google Drive works:
     First clear the test data in Supabase:
       truncate searches, activity_log, candidate_skills, cv_documents, candidates restart identity cascade;
     Then upload everything inside CVs/ to your CVs folder in Drive and run Workflow 1.
     answer_key.xlsx → "Files" shows what Workflow 1 should do with each file.

  3. Workflow 4 (transcript → job description):
     Use the 5 files in transcripts/. answer_key.xlsx → "Roles" lists what each
     client asked for, and the details they left unclear (the JD should flag them).

THE MESSY PARTS (ON PURPOSE)
  - 1 scanned CV with no text: scan_jreyes_cv.pdf (Jasmine Reyes)
  - 3 people twice: Claire Moussa (PDF + Word), Kofi Asante (exact copy "(1)"),
    Yara Fakhoury (new email, phone written differently)
  - 2 updated CVs: Mariam Tawfik (2023 → Oct 2026), Youssef Haddad (2024 → 2026)
  - 2 different people both called Ahmed Hassan (Cairo bookkeeper, Amman support agent)
