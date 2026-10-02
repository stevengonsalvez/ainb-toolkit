// ABOUTME: Beat targets: a CSS/Playwright selector string (as before), or a locator chain tried
// in order, and a miss that names the nearest candidates on the page.
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

export function toLocator(page, t) {
  if (typeof t === 'string') return page.locator(t);
  const base = t.in ? toLocator(page, t.in).first() : page;
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

// The page's own roles and names (its accessibility snapshot) plus its test ids, ranked by how
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
