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
  function paint(coll, sel, recs) {
    var by = {};
    recs.slice().sort(function (a, b) { return b.createdAt.localeCompare(a.createdAt); })
        .forEach(function (r) { (by[r.data.item] = by[r.data.item] || []).push(r); });

    document.querySelectorAll(sel + '[data-item]').forEach(function (box) {
      var rows = by[box.dataset.item] || [];
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

      var badge = document.querySelector('.answer-badge[data-badge="' + box.dataset.item + '"]');
      if (badge && rows.length) {
        if (coll === DEC) {
          badge.className = 'answer-badge decided';
          badge.textContent = 'decided: ' + rows[0].data.choice;
        } else if (!badge.classList.contains('decided')) {
          badge.className = 'answer-badge commented';
          badge.textContent = rows.length + ' comment' + (rows.length > 1 ? 's' : '');
        }
      }
    });
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
    var btn = box.querySelector('.submit');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var picked = box.querySelector('input[type=radio]:checked');
      var msg = box.querySelector('.submit-msg');
      if (!picked) { msg.className = 'submit-msg err'; msg.textContent = 'Pick an option'; return; }
      var ta = box.querySelector('textarea');
      send(box, DEC, { choice: picked.value, note: ta ? ta.value.trim() : '' }, btn);
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

  refresh();
})();
