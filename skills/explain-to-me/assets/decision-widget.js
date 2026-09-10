/* Decision capture widget for here.now Site Data. Pairs with decision-widget.css.
 *
 * Markup contract:
 *   <div class="who-bar"><label for="who-input">Recording as</label>
 *     <input id="who-input" required><span class="hint">…</span></div>
 *   The name is REQUIRED: submits are refused until it is filled, and it is
 *   stamped on every record so a decision log names who decided.
 *
 *   <div class="decision" data-item="B4">
 *     <h4>Your call</h4>
 *     <label class="opt"><input type="radio" name="d-B4" value="A">
 *       <span class="opt-body"><span class="opt-head">A · Title <em>recommended</em></span>
 *       <span class="opt-why">why</span><span class="opt-cost">cost</span></span></label>
 *     …
 *     <textarea rows="2" placeholder="Why (optional)"></textarea>
 *     <div class="submit-row"><button type="button" class="submit">Record decision</button>
 *       <span class="submit-msg"></span></div>
 *     <div class="answer-log"></div>
 *   </div>
 *
 *   Several questions on one item — tabs. Omit .qtabs/.qpane for a single question.
 *   <div class="decision" data-item="B4">
 *     <nav class="qtabs">
 *       <button class="qtab on" data-q="register">Which register</button>
 *       <button class="qtab" data-q="owner">Who takes it to Holly</button>
 *     </nav>
 *     <div class="qpane" data-q="register"><h4>Which register…?</h4> …opts… …submit… …log…</div>
 *     <div class="qpane" data-q="owner" hidden> … </div>
 *   </div>
 *
 *   <div class="feedback" data-item="B4"> … .stance[data-value] buttons … </div>
 *   <span class="answer-badge" data-badge="B4"></span>   (optional, anywhere)
 *
 * Collections default to "decisions" / "feedback"; override with
 *   window.DECISION_CONFIG = { decisions: 'x', feedback: 'y' } before this script.
 */
(function () {
  var CFG  = window.DECISION_CONFIG || {};
  var DEC  = CFG.decisions || 'decisions';
  var FB   = CFG.feedback  || 'feedback';
  var BASE = './.herenow/data/';           // MUST stay relative: works on slug, handle,
                                           // custom domain and mounted path alike.
  var WHO  = document.getElementById('who-input');
  var MSGCLS = 'submit-msg';
  // A republish invalidates the visitor session cookie, so an open page's writes start
  // 401ing while the already-rendered HTML still looks fine. We cannot re-auth from here
  // (no password in the page, by design), so stash what they typed, tell them plainly,
  // and restore it after they reload and sign in again.
  var DRAFT = 'explainer-draft';
  function stash(coll, payload) {
    try { localStorage.setItem(DRAFT, JSON.stringify({ coll: coll, payload: payload })); } catch (e) {}
  }
  function restore() {
    var d;
    try { d = JSON.parse(localStorage.getItem(DRAFT) || 'null'); } catch (e) { return; }
    if (!d || !d.payload || !d.payload.item) return;
    var sel = (d.coll === 'feedback' ? '.feedback' : '.decision') + '[data-item="' + d.payload.item + '"]';
    var box = document.querySelector(sel) || document.querySelector(
      (d.coll === 'feedback' ? '.act.fb' : '.act.decide') + '[data-code="' + d.payload.item + '"]');
    if (!box) return;
    var ta = box.querySelector('textarea');
    if (ta && d.payload.note) ta.value = d.payload.note;
    if (d.payload.choice) {
      var r = box.querySelector('input[type=radio][value="' + d.payload.choice + '"]');
      if (r) r.checked = true;
    }
    if (d.payload.stance) {
      var b = box.querySelector('[data-v="' + d.payload.stance + '"], [data-value="' + d.payload.stance + '"]');
      if (b) { box.querySelectorAll('.st, .stance').forEach(function (o) { o.classList.remove('on'); }); b.classList.add('on'); }
    }
    var det = box.closest('details'); if (det) det.open = true;
    var m = box.querySelector('.msg, .submit-msg');
    if (m) { m.className = (m.className.split(' ')[0]) + ''; m.textContent = 'Restored — press the button again to save'; }
    try { localStorage.removeItem(DRAFT); } catch (e) {}
    box.scrollIntoView({ block: 'center' });
  }

  var STANCE_LABEL = { agree: 'looks right', wrong: 'disagrees', discuss: 'needs discussion' };

  if (WHO) {
    try { WHO.value = localStorage.getItem('explainer-who') || ''; } catch (e) {}
    WHO.addEventListener('input', function () {
      try { localStorage.setItem('explainer-who', WHO.value.trim()); } catch (e) {}
    });
  }

  function esc(t) { var n = document.createElement('span'); n.textContent = t == null ? '' : t; return n.innerHTML; }
  function when(iso) {
    var d = new Date(iso);
    if (isNaN(d)) return '';
    return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) + ' ' +
           d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  }

  async function all(coll) {
    var out = [], cursor = null;
    for (var i = 0; i < 20; i++) {                       // hard cap: 2000 records
      var url = BASE + coll + '?limit=100' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : '');
      var res = await fetch(url);
      if (!res.ok) throw new Error(coll + ' HTTP ' + res.status);
      var page = await res.json();
      out = out.concat(page.records || []);
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  // Insert-only log: newest record for an item is the standing answer.
  function key(item, q) { return item + '\u0000' + (q || ''); }

  function paint(coll, sel, recs) {
    var by = {};
    recs.slice().sort(function (a, b) { return b.createdAt.localeCompare(a.createdAt); })
        .forEach(function (r) {
          var k = key(r.data.item, r.data.question);
          (by[k] = by[k] || []).push(r);
        });

    document.querySelectorAll(sel + '[data-item]').forEach(function (box) {
      // A pane per question, or the box itself when there is only one.
      var panes = box.querySelectorAll('.qpane');
      if (!panes.length) panes = [box];
      var answered = 0;
      Array.prototype.forEach.call(panes, function (pane) {
        var q = pane.dataset ? pane.dataset.q : '';
        var rows = by[key(box.dataset.item, q)] || [];
        if (rows.length) answered++;
        var tab = box.querySelector('.qtab[data-q="' + q + '"]');
        if (tab) {
          var t = tab.querySelector('.tick');
          if (rows.length && !t) { t = document.createElement('span'); t.className = 'tick'; t.textContent = '\u2713'; tab.appendChild(t); }
          else if (!rows.length && t) { t.remove(); }
        }
        paintPane(coll, pane, rows);
      });
      var badge = document.querySelector('.answer-badge[data-badge="' + box.dataset.item + '"]');
      if (badge && answered) {
        badge.className = 'answer-badge ' + (coll === DEC ? 'decided' : 'commented');
        badge.textContent = panes.length > 1
          ? answered + '/' + panes.length + ' answered'
          : (coll === DEC ? 'decided' : answered + ' comment' + (answered > 1 ? 's' : ''));
      }
    });
  }

  function paintPane(coll, box, rows) {
    {
      var log  = box.querySelector('.answer-log');
      // Append-only: show EVERY answer, newest first, never just the winner.
      // People need to see they disagreed, and who else has already answered.
      var head = rows.length
        ? '<div class="answer-head">' + rows.length + (coll === DEC ? ' answer' : ' comment') +
          (rows.length > 1 ? 's' : '') + ' so far · newest first</div>'
        : '';
      if (log) log.innerHTML = head + rows.map(function (r) {
        var what = coll === DEC
          ? 'chose <b>' + esc(r.data.choice) + '</b>'
          : '<b>' + esc(STANCE_LABEL[r.data.stance] || r.data.stance) + '</b>';
        return '<div class="answer"><b>' + esc(r.data.who) + '</b> ' + what + ' · ' +
               when(r.createdAt) + (r.data.note ? '<br>' + esc(r.data.note) : '') + '</div>';
      }).join('');

    }
  }

  async function refresh() {
    try { paint(DEC, '.decision', await all(DEC)); } catch (e) { console.warn(e); }
    try { paint(FB,  '.feedback', await all(FB));  } catch (e) { console.warn(e); }
  }

  async function send(box, coll, payload, btn) {
    var msg = box.querySelector('.submit-msg');
    var who = WHO ? (WHO.value || '').trim() : '';
    if (WHO && !who) {
      msg.className = 'submit-msg err'; msg.textContent = 'Add your name first';
      WHO.focus(); return;
    }
    payload.item = box.dataset.item;
    if (payload.question === undefined && box.dataset.q) payload.question = box.dataset.q;
    if (who) payload.who = who;
    btn.disabled = true;
    msg.className = 'submit-msg'; msg.textContent = 'Saving…';
    try {
      var res = await fetch(BASE + coll, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'Idempotency-Key': (crypto.randomUUID ? crypto.randomUUID()
                                                : String(Date.now()) + Math.random())
        },
        body: JSON.stringify(payload)
      });
        if (res.status === 401 || res.status === 403) {
          stash(coll, payload);
          msg.className = MSGCLS + ' err';
          msg.innerHTML = 'Session expired (the page was republished). ' +
            '<a href="#" class="relink">Reload and sign in</a> — your answer is saved.';
          var a = msg.querySelector('.relink');
          if (a) a.addEventListener('click', function (ev) { ev.preventDefault(); location.reload(); });
          return;
        }
      if (!res.ok) {
        var body = await res.json().catch(function () { return {}; });
        throw new Error(body.message || body.error || ('HTTP ' + res.status));
      }
      msg.textContent = 'Saved';
      var ta = box.querySelector('textarea'); if (ta) ta.value = '';
      await refresh();
    } catch (err) {
      msg.className = 'submit-msg err';
      msg.textContent = 'Not saved: ' + err.message;   // never swallow: a lost answer must be visible
    } finally { btn.disabled = false; }
  }

  document.querySelectorAll('.decision[data-item]').forEach(function (box) {
    var tabs  = box.querySelectorAll('.qtab');
    var panes = box.querySelectorAll('.qpane');
    Array.prototype.forEach.call(tabs, function (tab) {
      tab.addEventListener('click', function () {
        Array.prototype.forEach.call(tabs, function (t) { t.classList.toggle('on', t === tab); });
        Array.prototype.forEach.call(panes, function (p) { p.hidden = p.dataset.q !== tab.dataset.q; });
      });
    });
    var targets = panes.length ? panes : [box];
    Array.prototype.forEach.call(targets, function (pane) {
      var btn = pane.querySelector('.submit');
      if (!btn) return;
      btn.addEventListener('click', function () {
        var picked = pane.querySelector('input[type=radio]:checked');
        var msg = pane.querySelector('.submit-msg');
        if (!picked) { msg.className = 'submit-msg err'; msg.textContent = 'Pick an option'; return; }
        var ta = pane.querySelector('textarea');
        // send() reads data-item off the element it is given, so pass the item down.
        pane.dataset.item = box.dataset.item;
        send(pane, DEC, { choice: picked.value, note: ta ? ta.value.trim() : '',
                          question: pane.dataset.q || undefined }, btn);
      });
    });
  });

  document.querySelectorAll('.feedback[data-item]').forEach(function (box) {
    box.querySelectorAll('.stance').forEach(function (b) {
      b.addEventListener('click', function () {
        box.querySelectorAll('.stance').forEach(function (o) { o.classList.remove('on'); });
        b.classList.add('on');
      });
    });
    var btn = box.querySelector('.submit');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var on = box.querySelector('.stance.on');
      var msg = box.querySelector('.submit-msg');
      if (!on) { msg.className = 'submit-msg err'; msg.textContent = 'Pick one'; return; }
      var ta = box.querySelector('textarea');
      send(box, FB, { stance: on.dataset.value, note: ta ? ta.value.trim() : '' }, btn);
    });
  });

  restore();
  refresh();
})();
