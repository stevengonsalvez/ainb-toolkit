// ABOUTME: Beat targets: a CSS/Playwright selector string (as before), or a locator chain tried
// in order, plus what the authoring tools need around them: a miss that names the nearest
// candidates, a lint for CSS where a role or test id would do, and an inventory of a page.
//
// A target is a string, an object, or an array of them (a chain):
//   'header nav >> text=Fares'                     a selector (a single string keeps the old
//                                                  meaning: its first match)
//   { role: 'link', name: 'Fares' }                page.getByRole, exact name
//   { testid: 'nav-fares' }                        page.getByTestId
//   { text: 'Fares' } { label: 'Email' } { placeholder: 'Search' }    exact getBy*
//   { css: '#fares' }                              a selector inside a chain
//   any object may add `in: <target>` to search inside that element first
// A chain entry matches when it finds exactly one visible element; the first that does wins.

export class LocatorMiss extends Error {}

const ROLE_OF = { A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', TABLE: 'table', TR: 'row', TD: 'cell', TH: 'columnheader',
  NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', UL: 'list', OL: 'list', LI: 'listitem', IMG: 'img', FORM: 'form',
  H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', SUMMARY: 'button', DIALOG: 'dialog' };

export function toLocator(page, t) {
  if (typeof t === 'string') return page.locator(t);
  const base = t.in ? toLocator(page, t.in) : page;              // inside any element it matches
  if (t.role) return base.getByRole(t.role, t.name != null ? { name: t.name, exact: true } : {});
  if (t.testid) return base.getByTestId(t.testid);
  if (t.text) return base.getByText(t.text, { exact: true });
  if (t.label) return base.getByLabel(t.label, { exact: true });
  if (t.placeholder) return base.getByPlaceholder(t.placeholder, { exact: true });
  if (t.css) return base.locator(t.css);
  throw new Error(`target ${JSON.stringify(t)}: give a selector string or one of role, testid, text, label, placeholder, css`);
}

export function describe(t) {
  if (typeof t === 'string') return `'${t}'`;
  const q = (s) => JSON.stringify(s);
  const head = t.role ? `role=${t.role}${t.name != null ? `[name=${q(t.name)}]` : ''}` : t.testid ? `testid=${t.testid}` : t.text ? `text=${q(t.text)}`
    : t.label ? `label=${q(t.label)}` : t.placeholder ? `placeholder=${q(t.placeholder)}` : t.css ? `css=${t.css}` : JSON.stringify(t);
  return t.in ? `${head} in ${describe(t.in)}` : head;
}
const chainOf = (t) => (Array.isArray(t) ? t : [t]);

// Resolve a target for one use in one beat. Waits up to `waitMs` on the caller's clock (the take
// clock while filming) for the page to render it, then fails naming every entry tried, how many
// visible elements each found, and the nearest candidates on the page. A lone string keeps its
// old meaning: its first match (visible, for `ready`).
export async function resolve(page, target, { use, beat, waitMs = 5000, now = Date.now, sleep = (ms) => page.waitForTimeout(ms) }) {
  const chain = chainOf(target), legacy = typeof target === 'string';
  if (!chain.length) throw new Error(`beat "${beat}": ${use} target is an empty chain`);
  const end = now() + waitMs;
  for (;;) {
    const tried = [];
    for (const [i, t] of chain.entries()) {
      const loc = toLocator(page, t);
      if (legacy) {
        const first = loc.first(), n = await loc.count();
        if (use === 'ready' ? await first.isVisible().catch(() => false) : n > 0) return { loc: first, matched: describe(t), index: 0, of: 1 };
        tried.push(`${describe(t)} (${n} found${use === 'ready' && n ? ', none visible' : ''})`);
        continue;
      }
      const vis = loc.filter({ visible: true }), n = await vis.count();
      if (n === 1) return { loc: vis, matched: describe(t), index: i, of: chain.length };
      tried.push(`${describe(t)} (${n} visible)`);
    }
    if (now() >= end) {
      const near = await nearest(page, chain).catch(() => []);
      throw new LocatorMiss(`beat "${beat}": ${use} target matched no single visible element after ${waitMs}ms. Tried ${tried.join(', ')}.`
        + (near.length ? ` Nearest on the page: ${near.join(', ')}.` : ''));
    }
    await sleep(100);
  }
}

// The page's own roles and names (its accessibility tree) plus its test ids, ranked by how
// alike they are to the names, texts and test ids the chain asked for.
async function nearest(page, chain, k = 6) {
  const snap = await page.locator('body').ariaSnapshot({ timeout: 2000 });
  const seen = new Map();
  for (const line of snap.split('\n')) {
    const m = line.match(/^\s*- ([a-z]+)(?: "((?:[^"\\]|\\.)*)")?/);
    if (m && m[2] && !['text', 'paragraph', 'generic'].includes(m[1])) { const key = `${m[1]} ${JSON.stringify(m[2])}`; seen.set(key, (seen.get(key) || 0) + 1); }
  }
  for (const id of await page.evaluate(() => [...document.querySelectorAll('[data-testid]')].map((n) => n.getAttribute('data-testid')))) seen.set(`testid=${id}`, 1);
  const wants = chain.flatMap(function want(t) {
    if (typeof t === 'string') return t.match(/[A-Za-z][\w-]{2,}/g) || [];
    return [t.name, t.text, t.label, t.placeholder, t.testid, t.css, ...(t.in ? want(t.in) : [])].filter(Boolean).map(String);
  });
  const grams = (s) => { s = s.toLowerCase(); const g = new Set(); for (let i = 0; i < s.length - 1; i++) g.add(s.slice(i, i + 2)); return g; };
  const dice = (a, b) => { const A = grams(a), B = grams(b); let n = 0; for (const x of A) if (B.has(x)) n++; return A.size + B.size ? (2 * n) / (A.size + B.size) : 0; };
  return [...seen].map(([key, n]) => ({ key: n > 1 ? `${key} (x${n})` : key, s: Math.max(0, ...wants.map((w) => dice(w, key))) }))
    .sort((a, b) => b.s - a.s).slice(0, k).map((c) => c.key);
}

// The element's role and accessible name as the accessibility tree has them (the first line of
// its aria snapshot, so an input type=search is a searchbox and a button holding an img alt="Save"
// is named Save), its test id, and the landmark around it. Role and name are null for a plain
// container: its snapshot's first line is a child's, so the tag decides whether to read it.
export async function identify(loc) {
  const el = await loc.evaluate((n, ROLE_OF) => {
    const own = !!(n.getAttribute('role') || n.tagName === 'INPUT' || (n.tagName === 'A' ? n.hasAttribute('href') : ROLE_OF[n.tagName]));
    // the nearest landmark around it, to scope a role and name that is not unique on the page
    const lm = n.parentElement?.closest('nav,header,main,footer,aside,form,[role=navigation],[role=banner],[role=main],[role=contentinfo],[role=complementary],[role=form]');
    const LM = { NAV: 'navigation', HEADER: 'banner', MAIN: 'main', FOOTER: 'contentinfo', ASIDE: 'complementary', FORM: 'form' };
    return { own, testid: n.getAttribute('data-testid'), landmark: lm ? lm.getAttribute('role') || LM[lm.tagName] : null };
  }, ROLE_OF, { timeout: 2000 });
  el.role = el.name = null;
  if (el.own) {
    const m = (await loc.ariaSnapshot({ timeout: 2000 }).catch(() => '')).split('\n')[0].match(/^\s*- ([a-z]+)(?: "((?:[^"\\]|\\.)*)")?/);
    if (m) { el.role = m[1]; el.name = m[2] ? JSON.parse(`"${m[2]}"`) : null; }
  }
  return el;
}

// The steadiest single locator for a resolved element: role and name (inside its landmark when
// the page has others like it), else test id, when that finds this very element and nothing else;
// null when only a selector will do. Pass identify()'s result when it is already to hand.
export async function better(page, loc, el = null) {
  el ??= await identify(loc);
  const handle = await loc.elementHandle({ timeout: 2000 });
  const same = async (t) => {
    const vis = toLocator(page, t).filter({ visible: true });
    return (await vis.count()) === 1 && vis.evaluate((n, h) => n === h, handle);
  };
  try {
    if (el.role) {
      const t = el.name ? { role: el.role, name: el.name } : { role: el.role };
      if (await same(t)) return t;
      if (el.landmark) { const u = { ...t, in: { role: el.landmark } }; if (await same(u)) return u; }
    }
    if (el.testid) { const t = { testid: el.testid }; if (await same(t)) return t; }
    return null;
  } finally { await handle.dispose(); }
}

// A target as it is written in a beats file.
export const source = (t) => (typeof t === 'string' ? JSON.stringify(t)
  : `{ ${Object.entries(t).map(([k, v]) => `${k}: ${typeof v === 'object' ? source(v) : JSON.stringify(String(v))}`).join(', ')} }`);

// Lint: a selector (a lone string, or a chain that matched on a css entry) where a role or test id
// would find the same element. Selectors break when markup or class names change; roles and test
// ids survive a restyle.
export async function lintTarget(page, target, hit) {
  const t = chainOf(target)[hit.index];
  if (typeof t !== 'string' && !t.css) return null;
  const b = await better(page, hit.loc).catch(() => null);
  return b && `${describe(t)} is a selector; ${source(b)} finds the same element and survives a restyle`;
}

// Everything on the page a beat might target: interactive elements, landmarks, headings, tables,
// anything with an id or a test id. The top document only: open shadow roots and iframes are not
// walked (target inside them with a selector, or `in:` an element that holds them). Each with its role, name, test id, id, rect (CSS px) and the
// chain to use for it (steadiest first). For the authoring procedure in SKILL.md.
export async function inventory(page) {
  const items = await page.evaluate((ROLE_OF) => {
    const sel = 'a[href],button,input,select,textarea,summary,[role],[data-testid],[id],h1,h2,h3,h4,table,tr,nav,main,dialog,[tabindex]';
    return [...document.querySelectorAll(sel)].map((n, i) => {
      const b = n.getBoundingClientRect(), cs = getComputedStyle(n);
      if (!(b.width > 0 && b.height > 0) || cs.visibility === 'hidden' || n.closest('#__cur,#__ring')) return null;
      n.setAttribute('data-demo-inv', String(i));
      return { i, tag: n.tagName.toLowerCase(), id: n.id || null, testid: n.getAttribute('data-testid'),
        rect: { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) },
        text: (n.innerText || n.getAttribute('placeholder') || n.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().slice(0, 60) };
    }).filter(Boolean);
  }, ROLE_OF);
  const out = [];
  for (const it of items) {
    const loc = page.locator(`[data-demo-inv="${it.i}"]`);
    const el = await identify(loc);
    const chain = [];
    const b = await better(page, loc, el);
    if (b) chain.push(b);
    if (it.testid && !b?.testid) chain.push({ testid: it.testid });
    if (it.id) chain.push(`#${it.id}`);
    out.push({ role: el.role, name: el.name, testid: it.testid, id: it.id, tag: it.tag, rect: it.rect, text: it.text, chain });
  }
  await page.evaluate(() => document.querySelectorAll('[data-demo-inv]').forEach((n) => n.removeAttribute('data-demo-inv')));
  return out;
}
