# GoHighLevel setup

No API key and no Private Integration are needed. n8n sends approved candidates to a GoHighLevel workflow with an **Inbound Webhook** trigger, and GoHighLevel calls n8n back with a plain **Webhook** action when a candidate replies.

Pipeline **Candidates**, stages: Contacted → Replied → Interview → Submitted to client → Hired → Not a fit.

## 1. Copilot · Candidate outreach

Started by WF5b, once per approved candidate.

| Step | Settings |
|---|---|
| Trigger: **Inbound Webhook** | Premium trigger, billed per run. WF5b posts: `first_name`, `last_name`, `full_name`, `email`, `role_title`, `client_company`, `opportunity_name`, `score`, `cv_file_name`, `cv_url`, `shortlist_id`, `role_id`, `source`. A sample request must be sent once and selected as the mapping reference. |
| Create Contact | First Name, Last Name and **Email** from the webhook (Email is required: GoHighLevel matches contacts by it) |
| Add Contact Tag | `copilot-outreach` |
| Create/Update Opportunity | Pipeline **Candidates**, stage **Contacted**, name = `opportunity_name` |
| Send Email 1 → Wait 2 days → Send Email 2 → Wait 3 days → Send Email 3 | Texts in `outreach_emails.txt`. From Name and From Email left empty, so the account's default sender is used and replies come back into GoHighLevel. |
| Workflow **Settings** | **Stop on response: on** |

Email only. The test CVs' phone numbers are invented and may belong to real people, so there are no SMS or call steps.

## 2. Copilot · Candidate replied

| Step | Settings |
|---|---|
| Trigger: **Customer Replied** | Reply channel = Email |
| If/Else, branch "Copilot candidate" | Contact → Tags includes `copilot-outreach` (the account is shared: other contacts' replies are ignored) |
| Create/Update Opportunity | Pipeline **Candidates**, stage **Replied** |
| Webhook (plain, not Custom Webhook) | POST to WF6's production URL, custom data `email` = Contact → Email |

WF6 then calls `ghl_reply()` in Supabase (stage → Replied in the portal) and posts 💬 to Slack.

## Testing with the fictional candidates

The test CVs use example.com addresses, which never deliver. WF5b's **Build GoHighLevel request** node has a `DEMO_INBOX` setting: put your own inbox there and each candidate gets their own address in it (`you+rania.khoury@gmail.com`, …), so the emails reach you and every candidate stays a separate contact. Set it to `''` for real candidates.

**Known limit:** when you reply from that inbox, the reply comes from your main address, not the `+name` one, so GoHighLevel files it under a different contact and the Replied step doesn't run. Real candidates reply from the address on their contact. To test the reply path, reply from a mailbox whose address is exactly the one on the contact.
