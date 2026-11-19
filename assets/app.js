/* Recruiting Copilot · recruiter portal
 *
 * A small single-page app with no build step and no libraries.
 * It signs in with Supabase Auth and reads the portal_* views through
 * Supabase's REST API. Pages: Today, Roles, Pipeline, CV library, Copilot test.
 */
(function () {
  'use strict';

  const CFG = window.PORTAL_CONFIG || {};
  const URL_BASE = String(CFG.supabaseUrl || '').replace(/\/+$/, '');
  const KEY = String(CFG.supabaseKey || '');
  const SESSION_KEY = 'recruiter-portal-session';
  const app = document.getElementById('app');

  // ------------------------------------------------------------------ helpers
  const esc = (v) => String(v == null ? '' : v)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  const num = (v) => (v == null ? 0 : Number(v));
  const plural = (n, one, many) => `${n} ${n === 1 ? one : (many || one + 's')}`;
  const dateFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const dayFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  const when = (v) => (v ? dateFmt.format(new Date(v)) : '');
  const day = (v) => (v ? dayFmt.format(new Date(v)) : '');
  const safeUrl = (u) => (/^https?:\/\//i.test(String(u || '')) ? String(u) : '');
  const cvLink = (name, url) => {
    if (!name) return '<span class="muted">No CV</span>';
    const href = safeUrl(url);
    return href ? `<a href="${esc(href)}" target="_blank" rel="noopener">${esc(name)}</a>` : esc(name);
  };

  const store = {
    get() { try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); } catch (e) { return null; } },
    set(s) { try { localStorage.setItem(SESSION_KEY, JSON.stringify(s)); } catch (e) { /* private window: stay signed in for this tab only */ } memorySession = s; },
    clear() { try { localStorage.removeItem(SESSION_KEY); } catch (e) { /* ignore */ } memorySession = null; },
  };
  let memorySession = store.get();

  // ------------------------------------------------------------------ Supabase (plain fetch)
  class ApiError extends Error {
    constructor(message, status, code) { super(message); this.status = status; this.code = code; }
  }

  async function authRequest(grant, body) {
    const res = await fetch(`${URL_BASE}/auth/v1/token?grant_type=${grant}`, {
      method: 'POST',
      headers: { apikey: KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new ApiError(data.error_description || data.msg || data.message || `Sign-in failed (${res.status})`, res.status, data.error_code || data.error);
    return { access_token: data.access_token, refresh_token: data.refresh_token, email: data.user && data.user.email };
  }

  async function signIn(email, password) { store.set(await authRequest('password', { email, password })); }

  async function refreshSession() {
    const s = memorySession;
    if (!s || !s.refresh_token) throw new ApiError('Signed out', 401);
    const fresh = await authRequest('refresh_token', { refresh_token: s.refresh_token });
    store.set({ ...fresh, email: fresh.email || s.email });
  }

  function signOut() {
    const s = memorySession;
    store.clear();
    if (s && s.access_token) {
      fetch(`${URL_BASE}/auth/v1/logout`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${s.access_token}` } }).catch(() => {});
    }
    location.hash = '#/';
    render();
  }

  // GET a portal view. query = { order: 'created_at.desc', limit: 10 }
  async function read(view, query, retried) {
    const s = memorySession;
    if (!s) throw new ApiError('Signed out', 401);
    const params = new URLSearchParams({ select: '*', ...(query || {}) });
    const res = await fetch(`${URL_BASE}/rest/v1/${view}?${params}`, {
      headers: { apikey: KEY, Authorization: `Bearer ${s.access_token}`, Accept: 'application/json' },
    });
    if (res.status === 401 && !retried) {
      await refreshSession();
      return read(view, query, true);
    }
    const data = await res.json().catch(() => null);
    if (!res.ok) {
      const msg = (data && (data.message || data.hint)) || `Request failed (${res.status})`;
      throw new ApiError(msg, res.status, data && data.code);
    }
    return data || [];
  }

  // ------------------------------------------------------------------ words used across pages
  const ROLE_STATUS = {
    approved: ['Open', 'good'],
    pending_approval: ['Waiting for approval', 'wait'],
    rejected: ['Declined', 'bad'],
    filled: ['Filled', ''],
    closed: ['Closed', ''],
  };
  const STAGES = [
    ['contacted', 'Contacted'],
    ['replied', 'Replied'],
    ['interview', 'Interview'],
    ['submitted_to_client', 'Submitted to client'],
    ['hired', 'Hired'],
    ['not_a_fit', 'Not a fit'],
  ];
  const STAGE_NAME = Object.fromEntries(STAGES);
  const SOURCE_NAME = { slack: 'Slack', test: 'Test run', shortlist: 'Shortlist', manual: 'Manual' };

  const roleTag = (status) => {
    const [label, cls] = ROLE_STATUS[status] || [status, ''];
    return `<span class="tag ${cls}">${esc(label)}</span>`;
  };
  const decisionTag = (row) => {
    if (row.decision === 'waiting_approval') return '<span class="tag wait">Your decision</span>';
    if (row.decision === 'declined') return '<span class="tag bad">Declined</span>';
    const label = STAGE_NAME[row.stage] || 'Approved';
    return `<span class="tag good">${esc(label)}</span>${row.ghl_mode === 'test' ? ' <span class="tag test" title="GoHighLevel is in test mode: nobody was emailed">test mode</span>' : ''}`;
  };
  const meter = (score) => {
    const s = Math.max(0, Math.min(100, num(score)));
    return `<div class="meter" title="${s} out of 100. The line marks 60, the lowest score the copilot will suggest."><b>${s}</b><div class="bar"><i style="width:${s}%"></i></div></div>`;
  };

  // ten dots, one per test question: filled = right, red = wrong, empty = not run
  function dots(results, opts) {
    const o = opts || {};
    const byN = new Map((results || []).map((r) => [Number(r.n), r]));
    const items = [];
    for (let n = 1; n <= 10; n++) {
      const r = byN.get(n);
      const cls = r ? (r.right ? 'right' : 'wrong') : '';
      const title = r ? `Question ${n}: ${r.right ? 'right' : 'wrong'}` : `Question ${n}: not run yet`;
      const inner = o.numbers === false ? '' : String(n);
      items.push(o.link
        ? `<a class="${cls}" href="#/test" data-jump="q${n}" title="${esc(title)}">${inner}<span class="visually-hidden">${esc(title)}</span></a>`
        : `<span class="${cls}" title="${esc(title)}">${inner}</span>`);
    }
    return `<div class="dots${o.big ? ' big' : ''}" role="img" aria-label="${esc(o.label || 'Test results')}">${items.join('')}</div>`;
  }

  // ------------------------------------------------------------------ layout
  const NAV = [
    ['today', '#/', 'Today'],
    ['roles', '#/roles', 'Roles'],
    ['pipeline', '#/pipeline', 'Pipeline'],
    ['cvs', '#/cvs', 'CV library'],
    ['test', '#/test', 'Copilot test'],
  ];
  const CEDAR = '<svg width="34" height="34" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="7" fill="#2e5a44"/><path d="M16 5 9 13h4l-6 7h5l-5 6h18l-5-6h5l-6-7h4z" fill="#f1c84b"/></svg>';

  let lastWaiting = 0;   // remembered so the Pipeline badge stays put on every page
  function shell(active, body, badge) {
    const s = memorySession || {};
    if (badge != null) lastWaiting = badge; else badge = lastWaiting;
    const nav = NAV.map(([id, href, label]) => {
      const count = id === 'pipeline' && badge ? `<span class="count" title="${esc(plural(badge, 'candidate'))} waiting for your decision">${badge}</span>` : '';
      return `<a href="${href}"${id === active ? ' aria-current="page"' : ''}><span>${label}</span>${count}</a>`;
    }).join('');
    return `<div class="shell">
      <aside class="rail">
        <a class="brand" href="#/">${CEDAR}<span><b>Cedar Remote Talent</b><span>Recruiting Copilot</span></span></a>
        <nav class="nav" aria-label="Portal">${nav}</nav>
        <div class="rail-foot"><span>${esc(s.email || '')}</span><button type="button" data-action="signout">Sign out</button></div>
      </aside>
      <main id="main" tabindex="-1">${body}</main>
    </div>`;
  }

  function errorView(err) {
    let help = 'Try again in a minute.';
    if (/fetch|network/i.test(err.message)) help = 'Check your internet connection. If it works, your Supabase project may be paused: resume it in Supabase → Project Overview.';
    if (err.code === '42501' || /permission denied/i.test(err.message)) help = 'This login can\'t read the portal views. Run portal_setup.sql in the Supabase SQL Editor.';
    if (err.code === '42P01' || err.code === 'PGRST205' || /does not exist|could not find/i.test(err.message)) help = 'The portal views are missing. Run portal_setup.sql in the Supabase SQL Editor.';
    return `<div class="error-box"><h2>Couldn't load this page</h2><p>${esc(err.message)}</p><p class="muted">${esc(help)}</p></div>`;
  }

  // ------------------------------------------------------------------ pages
  async function pageToday() {
    const [ov, waiting, runs, searches] = await Promise.all([
      read('portal_overview').then((r) => r[0] || {}),
      read('portal_shortlist', { decision: 'eq.waiting_approval', order: 'score.desc' }),
      read('portal_test_runs', { order: 'ran_at.desc', limit: '1' }),
      read('portal_searches', { order: 'asked_at.desc', limit: '6' }),
    ]);
    const nWait = waiting.length;
    const pendingRoles = num(ov.roles_pending);
    let lede = 'Nothing is waiting for your decision.';
    if (nWait) lede = nWait === 1 ? '1 candidate is waiting for your decision.' : `${nWait} candidates are waiting for your decision.`;
    else if (pendingRoles) lede = pendingRoles === 1 ? '1 job description is waiting for your approval.' : `${pendingRoles} job descriptions are waiting for your approval.`;

    const waitList = nWait
      ? `<ul class="waiting-list">${waiting.slice(0, 8).map((w) => `<li>
          <div><span class="person">${esc(w.full_name)}</span><div class="small muted">for ${esc(w.role_title)} at ${esc(w.client_company)}</div></div>
          <div>${meter(w.score)}</div>
        </li>`).join('')}</ul><p class="small muted" style="margin-top:12px">Approve or decline each one in #ask-copilot on Slack. Nobody is contacted before you approve.</p>`
      : '<p class="empty">When a job description is approved, its shortlist appears here until you decide on each candidate.</p>';

    const run = runs[0];
    const testPanel = `<div class="panel">
      <h2>Copilot test</h2>
      ${dots(run ? run.results : [], { link: true, label: run ? `${run.score} of ${run.total} questions right` : 'No test run yet' })}
      ${run
        ? `<div class="score-line"><b>${num(run.score)}/${num(run.total)}</b><span class="muted">right on ${esc(when(run.ran_at))}</span></div>`
        : '<p class="muted" style="margin-top:10px">No test run yet. Run "WF3 · Test runner" in n8n.</p>'}
      <a href="#/test">See the questions and answers</a>
    </div>`;

    const stageCounts = {};
    if (num(ov.in_pipeline)) {
      const rows = await read('portal_shortlist', { decision: 'eq.approved', select: 'stage' });
      rows.forEach((r) => { stageCounts[r.stage] = (stageCounts[r.stage] || 0) + 1; });
    }
    const track = `<ol class="track">${STAGES.map(([id, label]) => {
      const n = stageCounts[id] || 0;
      return `<li class="${n ? 'has' : ''}"><div class="node">${n}</div><div class="label">${esc(label)}</div></li>`;
    }).join('')}</ol>`;

    const facts = [
      [num(ov.candidates), 'people you can search'],
      [num(ov.cv_files), 'CV files received'],
      [num(ov.scanned_files), 'read from a scan'],
      [num(ov.duplicate_files), 'duplicates kept once'],
      [num(ov.replaced_files), 'replaced by a newer CV'],
      [num(ov.flagged_files), "couldn't be read"],
    ].map(([n, label]) => `<div><b>${n}</b><span>${esc(label)}</span></div>`).join('');

    const searchList = searches.length
      ? `<ul class="search-list">${searches.map((s) => `<li>
          <div>${esc(s.question)}<div class="small muted">${esc(SOURCE_NAME[s.source] || s.source)}, ${esc(when(s.asked_at))}</div></div>
          <div class="small nowrap">${s.status === 'matches' ? esc(plural(num(s.results_count), 'match', 'matches')) : `<span class="muted">${esc(String(s.status || '').replace(/_/g, ' '))}</span>`}</div>
        </li>`).join('')}</ul>`
      : '<p class="empty">No searches yet. Ask the copilot something in #ask-copilot on Slack.</p>';

    return shell('today', `
      <div class="page-head"><p class="lede">${esc(lede)}</p>
        <p>${esc(plural(num(ov.roles_open), 'open role'))}, ${esc(plural(num(ov.approved_candidates), 'approved candidate'))} in the pipeline.</p></div>
      <div class="grid-2">
        <div class="panel"><h2>Waiting for you</h2><div style="margin-top:12px">${waitList}</div></div>
        ${testPanel}
      </div>
      <div class="section"><h2><a href="#/pipeline" style="color:inherit;text-decoration:none">Pipeline</a></h2><div class="panel">${track}</div></div>
      <div class="section"><h2><a href="#/cvs" style="color:inherit;text-decoration:none">CV library</a></h2><div class="facts">${facts}</div></div>
      <div class="section"><h2>Latest searches</h2><div class="panel">${searchList}</div></div>
    `, nWait);
  }

  async function pageRoles() {
    const [roles, shortlist] = await Promise.all([
      read('portal_roles', { order: 'created_at.desc' }),
      read('portal_shortlist', { order: 'rank.asc' }),
    ]);
    const waiting = shortlist.filter((s) => s.decision === 'waiting_approval').length;
    const order = { approved: 0, pending_approval: 1, filled: 2, closed: 3, rejected: 4 };
    roles.sort((a, b) => (order[a.status] ?? 9) - (order[b.status] ?? 9) || new Date(b.created_at) - new Date(a.created_at));

    const body = roles.length ? roles.map((r) => {
      const jd = r.jd || {};
      const rows = shortlist.filter((s) => s.role_id === r.role_id);
      const unclear = Array.isArray(r.open_questions) ? r.open_questions : [];
      const must = (jd.must_have || []).map((m) => esc(m.text)).join('; ');
      const nice = (jd.nice_to_have || []).map((m) => esc(m.text)).join('; ');
      const facts = [
        jd.hours_and_timezone && `Hours: ${esc(jd.hours_and_timezone)}`,
        `Pay: ${jd.budget ? esc(jd.budget) : '<span class="muted">not confirmed</span>'}`,
        `Start: ${jd.start_date ? esc(jd.start_date) : '<span class="muted">not confirmed</span>'}`,
      ].filter(Boolean).join('<br>');
      let table = '';
      if (rows.length) {
        table = `<div class="table-wrap"><table>
          <thead><tr><th>#</th><th>Candidate</th><th>Score</th><th>Why them, and the risk</th><th>CV</th><th>Status</th></tr></thead>
          <tbody>${rows.map((s) => `<tr>
            <td data-label="Rank"><div>${esc(s.rank)}</div></td>
            <td data-label="Candidate"><div><span class="person">${esc(s.full_name)}</span><div class="small muted">${esc(s.location || '')}</div></div></td>
            <td data-label="Score"><div>${meter(s.score)}</div></td>
            <td data-label="Why them, and the risk" class="reason"><div>${esc(s.why_fit)}<span class="risk">${esc(s.gap_or_risk)}</span></div></td>
            <td data-label="CV" class="small"><div>${cvLink(s.cv_file_name, s.cv_file_url)}</div></td>
            <td data-label="Status"><div>${decisionTag(s)}</div></td>
          </tr>`).join('')}</tbody></table></div>`;
      } else if (r.status === 'approved') {
        table = '<p class="empty">No shortlist yet. It starts automatically about a minute after the job description is approved.</p>';
      } else if (r.status === 'pending_approval') {
        table = '<p class="empty">Approve the job description in Slack to start its shortlist.</p>';
      }
      return `<article class="role ${esc(r.status)}" id="role-${esc(r.role_id)}">
        <div class="role-head">
          <div><h2>${esc(r.role_title)}</h2><p>${esc(r.client_company)}${r.hires ? `, ${esc(plural(num(r.hires), 'hire'))}` : ''}. Role #${esc(r.role_id)}, added ${esc(day(r.created_at))}.</p></div>
          ${roleTag(r.status)}
        </div>
        ${jd.summary ? `<p style="margin-top:12px;max-width:80ch">${esc(jd.summary)}</p>` : ''}
        <div class="grid-2" style="margin-top:8px">
          <div class="small">${must ? `<p><b>Must have:</b> ${must}</p>` : ''}${nice ? `<p><b>Nice to have:</b> ${nice}</p>` : ''}</div>
          <div class="small">${facts}</div>
        </div>
        ${unclear.length ? `<div class="unclear"><b>Check with the client</b><ul>${unclear.map((q) => `<li><b>${esc(q.topic)}:</b> ${esc(q.note)}</li>`).join('')}</ul></div>` : ''}
        ${r.search_question ? `<p class="search-q">Shortlist search: <i>${esc(r.search_question)}</i></p>` : ''}
        ${table}
        <details><summary>Full job description</summary><div class="jd">${esc(r.jd_text)}</div></details>
      </article>`;
    }).join('') : '<p class="empty">No roles yet. Submit a client call transcript with the "New client call" form in n8n.</p>';

    return shell('roles', `<div class="page-head"><h1>Roles</h1>
      <p>Every job description written from a client call, newest first, with the shortlist the copilot found for it.</p></div>${body}`, waiting);
  }

  async function pagePipeline() {
    const rows = await read('portal_shortlist', { order: 'score.desc' });
    const waiting = rows.filter((r) => r.board_column === 'awaiting_approval');
    const cols = [['awaiting_approval', 'Waiting for your decision', 'waiting']];
    if (rows.some((r) => r.board_column === 'approved')) cols.push(['approved', 'Approved', '']);
    STAGES.forEach(([id, label]) => cols.push([id, label, '']));
    cols.push(['declined', 'Declined by you', 'declined']);
    const anyTest = rows.some((r) => r.ghl_mode === 'test');

    const board = `<div class="board">${cols.map(([id, label, cls]) => {
      const items = rows.filter((r) => r.board_column === id);
      return `<section class="column ${cls}" aria-label="${esc(label)}">
        <h3><span>${esc(label)}</span><span class="muted">${items.length}</span></h3>
        ${items.map((r) => `<div class="card">
          <div class="person">${esc(r.full_name)}</div>
          <p>${esc(r.role_title)}, ${esc(r.client_company)}</p>
          <p>Score ${esc(num(r.score))}/100${r.ghl_mode === 'test' ? ', test mode' : ''}</p>
        </div>`).join('')}
      </section>`;
    }).join('')}</div>`;

    return shell('pipeline', `<div class="page-head"><h1>Pipeline</h1>
      <p>Every shortlisted candidate, by where they are now. Candidates only move past "Waiting for your decision" after you approve them in Slack.</p></div>
      ${anyTest ? '<div class="notice"><b>GoHighLevel is in test mode.</b> Approved candidates are tracked here, but none of them has been added to GoHighLevel or emailed yet.</div>' : ''}
      ${rows.length ? board : '<p class="empty">Nobody is on a shortlist yet.</p>'}`, waiting.length);
  }

  const FILE_STATUS = {
    indexed: ['Searchable', 'good'],
    duplicate: ['Same person, kept once', ''],
    exact_duplicate: ['Identical copy, skipped', ''],
    superseded: ['Replaced by a newer CV', ''],
    unreadable: ["Couldn't be read", 'bad'],
    unsupported: ['File type not supported', 'bad'],
    not_a_cv: ['Not a CV', 'bad'],
    error: ['Error, will retry', 'bad'],
  };
  const CV_FILTERS = [
    ['all', 'All files', () => true],
    ['searchable', 'Searchable', (f) => f.status === 'indexed'],
    ['duplicates', 'Duplicates', (f) => f.status === 'duplicate' || f.status === 'exact_duplicate'],
    ['replaced', 'Replaced', (f) => f.status === 'superseded'],
    ['scan', 'Read from a scan', (f) => (f.flags || []).includes('read_from_scan')],
    ['flagged', 'Flagged', (f) => ['unreadable', 'unsupported', 'not_a_cv', 'error'].includes(f.status) || (f.flags || []).includes('possible_duplicate')],
  ];

  async function pageCvs(query) {
    const files = await read('portal_cv_files', { order: 'received_at.desc' });
    const show = CV_FILTERS.find(([id]) => id === query.get('show')) || CV_FILTERS[0];
    const list = files.filter(show[2]);
    const filters = CV_FILTERS.map(([id, label, test]) => {
      const n = files.filter(test).length;
      return `<a href="#/cvs?show=${id}"${id === show[0] ? ' aria-current="true"' : ''}>${esc(label)} (${n})</a>`;
    }).join('');

    const notes = (f) => {
      const out = [];
      if ((f.flags || []).includes('read_from_scan')) out.push('Scanned image: read by the AI from the picture.');
      if ((f.flags || []).includes('possible_duplicate')) out.push(`Same name as ${f.same_name_as || 'another candidate'}, but different contact details, so kept as a separate person. Check before contacting.`);
      if (f.duplicate_of_file) out.push(`Copy of ${f.duplicate_of_file}.`);
      if (f.replaced_by_file) out.push(`Newer version: ${f.replaced_by_file}.`);
      if (f.status_reason && !['indexed'].includes(f.status) && !out.length) out.push(f.status_reason);
      return out.map(esc).join('<br>') || '<span class="muted">None</span>';
    };

    const table = list.length ? `<div class="panel table-wrap"><table>
      <thead><tr><th>File</th><th>Person</th><th>What happened</th><th>Notes</th><th>Received</th></tr></thead>
      <tbody>${list.map((f) => {
        const [label, cls] = FILE_STATUS[f.status] || [f.status, ''];
        return `<tr>
          <td data-label="File" class="file"><div>${cvLink(f.file_name, f.file_url)}</div></td>
          <td data-label="Person"><div>${f.candidate_name ? `<span class="person">${esc(f.candidate_name)}</span>` : '<span class="muted">Unknown</span>'}</div></td>
          <td data-label="What happened"><div><span class="tag ${cls}">${esc(label)}</span></div></td>
          <td data-label="Notes" class="small reason"><div>${notes(f)}</div></td>
          <td data-label="Received" class="small nowrap"><div>${esc(when(f.received_at))}</div></td>
        </tr>`;
      }).join('')}</tbody></table></div>` : `<p class="empty">No files in "${esc(show[1])}".</p>`;

    return shell('cvs', `<div class="page-head"><h1>CV library</h1>
      <p>Every file that reached the CV folder, and what the copilot did with it. Nothing is skipped silently: duplicates, older versions and unreadable files all stay listed here.</p></div>
      <nav class="filters" aria-label="Filter files">${filters}</nav>${table}`);
  }

  async function pageTest() {
    const [questions, runs] = await Promise.all([
      read('portal_test_questions', { order: 'n.asc' }),
      read('portal_test_runs', { order: 'ran_at.desc', limit: '8' }),
    ]);
    const run = runs[0];
    const byN = new Map(((run && run.results) || []).map((r) => [Number(r.n), r]));

    const head = `<div class="page-head"><h1>Copilot test</h1>
      <p>Ten questions with known right answers, asked to the copilot exactly as a recruiter would ask them in Slack. A question counts as right only when the copilot names exactly the right people, each with their own CV, and invents nobody.</p></div>
      <div class="panel" style="margin-bottom:28px">
        ${dots(run ? run.results : [], { big: true, link: true, label: run ? `${run.score} of ${run.total} questions right` : 'No test run yet' })}
        ${run ? `<div class="score-line"><b>${num(run.score)}/${num(run.total)}</b><span class="muted">latest run, ${esc(when(run.ran_at))}</span></div>`
              : '<p class="muted" style="margin-top:10px">No test run yet. Run "WF3 · Test runner" in n8n, then refresh this page.</p>'}
      </div>`;

    const qs = questions.map((q) => {
      const r = byN.get(Number(q.n));
      const cls = r ? (r.right ? 'right' : 'wrong') : '';
      const expected = q.expect_no_match
        ? '<p>Nobody matches. The copilot should say so and name no one.</p>'
        : `<ul>${(q.expected || []).map((e) => `<li>${esc(e.name)}<span class="file-name">${esc(e.cv_file_name)}</span></li>`).join('')}</ul>`;
      let got = '<p class="muted">Not run yet.</p>';
      if (r) {
        const people = r.bot_candidates || [];
        got = people.length
          ? `<ul>${people.map((p) => `<li>${esc(p.name)}${p.score != null ? `, ${esc(p.score)}/100` : ''}<span class="file-name">${esc(p.cv_file_name || 'no CV named')}</span></li>`).join('')}</ul>`
          : `<p>${r.bot_status === 'error' ? 'No answer (error).' : 'Nobody.'}</p>`;
      }
      const wrongPeople = (q.should_not_appear || []).map((t) => esc(t.name)).join(', ');
      return `<section class="q" id="q${esc(q.n)}">
        <div class="q-num ${cls}" aria-hidden="true">${esc(q.n)}</div>
        <div>
          <h3>${esc(q.question)}</h3>
          <div class="answers">
            <div><h4>Right answer</h4>${expected}</div>
            <div><h4>Copilot answered</h4>${got}</div>
          </div>
          ${r ? `<p class="verdict ${cls}">${r.right ? 'Right.' : 'Wrong.'} ${esc(r.why)}</p>` : ''}
          <p class="tricky">${esc(q.why_tricky)}${wrongPeople ? ` ${q.expect_no_match ? 'Closest, but still not a match' : 'Close but wrong'}: ${wrongPeople}.` : ''}</p>
        </div>
      </section>`;
    }).join('');

    const history = runs.length > 1 ? `<div class="section"><h2>Run history</h2><div class="panel"><ul class="history">${runs.map((x) => `<li>
        ${dots(x.results, { numbers: false, label: `${x.score} of ${x.total} right` })}
        <b>${num(x.score)}/${num(x.total)}</b><span class="muted small">${esc(when(x.ran_at))}</span></li>`).join('')}</ul></div></div>` : '';

    return shell('test', `${head}<div class="panel">${qs || '<p class="empty">No test questions found. Run wf3_test_setup.sql in Supabase.</p>'}</div>${history}`);
  }

  // ------------------------------------------------------------------ sign in
  function pageSignIn(message) {
    return `<div class="signin">
      <div class="signin-side">
        <a class="brand" href="#/">${CEDAR}<span><b>Cedar Remote Talent</b><span>Recruiting Copilot</span></span></a>
        <div><h1>Recruiter portal</h1>
          <p>Open roles and their shortlists, every candidate's place in the pipeline, the CV library, and how accurate the copilot is.</p></div>
        <p class="small">Test data only. Every candidate and client here is fictional.</p>
      </div>
      <form class="signin-form" id="signin" novalidate>
        <h2>Sign in</h2>
        <label for="email">Email</label>
        <input id="email" name="email" type="email" autocomplete="username" required>
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <button class="primary" type="submit">Sign in</button>
        <p class="form-error" id="signin-error" role="alert">${esc(message || '')}</p>
      </form>
    </div>`;
  }

  function setupNeeded() {
    return `<main style="padding:40px var(--gutter)"><div class="error-box"><h2>The portal isn't connected yet</h2>
      <p>Open <b>config.js</b> and fill in your Supabase project URL and key (Supabase → Project Settings → API).</p></div></main>`;
  }

  // ------------------------------------------------------------------ router
  const ROUTES = { '': pageToday, roles: pageRoles, pipeline: pagePipeline, cvs: pageCvs, test: pageTest };
  let renderId = 0;

  async function render() {
    const id = ++renderId;
    if (!URL_BASE || /YOUR-PROJECT-REF/.test(URL_BASE) || !KEY || /YOUR-/.test(KEY)) { app.innerHTML = setupNeeded(); return; }
    if (!memorySession) { app.innerHTML = pageSignIn(); bindSignIn(); return; }

    const hash = location.hash.replace(/^#\/?/, '');
    const [path, qs] = hash.split('?');
    const [page, anchor] = path.split('/');
    const fn = ROUTES[page] || pageToday;
    document.title = `${(NAV.find(([n]) => n === (page || 'today')) || NAV[0])[2]} · Recruiter Portal`;
    if (!app.querySelector('.shell')) app.innerHTML = shell(page || 'today', '<p class="muted">Loading…</p>');
    else { const m = document.getElementById('main'); if (m) m.setAttribute('aria-busy', 'true'); }
    try {
      const html = await fn(new URLSearchParams(qs || ''));
      if (id !== renderId) return;
      app.innerHTML = html;
      const target = anchor && document.getElementById(anchor.startsWith('q') ? anchor : `role-${anchor}`);
      if (target) target.scrollIntoView(); else window.scrollTo(0, 0);
    } catch (err) {
      if (id !== renderId) return;
      if (err.status === 401) { store.clear(); app.innerHTML = pageSignIn('Your session ended. Please sign in again.'); bindSignIn(); return; }
      app.innerHTML = shell(page || 'today', errorView(err));
    }
  }

  function bindSignIn() {
    const form = document.getElementById('signin');
    if (!form) return;
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const btn = form.querySelector('button');
      const out = document.getElementById('signin-error');
      const email = form.email.value.trim();
      const password = form.password.value;
      if (!email || !password) { out.textContent = 'Enter your email and password.'; return; }
      btn.disabled = true; btn.textContent = 'Signing in…'; out.textContent = '';
      try {
        await signIn(email, password);
        render();
      } catch (err) {
        btn.disabled = false; btn.textContent = 'Sign in';
        out.textContent = err.status === 400 || err.status === 401
          ? "That email and password don't match a portal login."
          : `Couldn't sign in: ${err.message}`;
      }
    });
  }

  document.addEventListener('click', (e) => {
    const out = e.target.closest('[data-action="signout"]');
    if (out) { e.preventDefault(); signOut(); return; }
    const jump = e.target.closest('[data-jump]');
    if (jump) {
      e.preventDefault();
      const target = jump.dataset.jump;
      if (location.hash.startsWith('#/test') && document.getElementById(target)) document.getElementById(target).scrollIntoView();
      else location.hash = `#/test/${target}`;
    }
  });
  window.addEventListener('hashchange', render);
  render();
})();
