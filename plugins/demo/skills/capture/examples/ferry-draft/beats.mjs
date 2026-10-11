// Drafted from scratch with "Drafting beats" in ../../SKILL.md, for the goal "show a late sailing
// and the resident fare" on the ferry example app (../../../compose/examples/ferry: run its
// serve.mjs first). Targets come from inventory.mjs: role and name first, the selector last, and
// '#next' alone because that card has no role. Each chapter puts its first mark on screen inside
// 3s, and the narration in draft.config.json runs 115 to 140 words a minute.
import { fileURLToPath } from 'node:url';
const lateRow = [{ role: 'row', name: '14:20 Mainland to Skerry MV Cormorant 12 min late Fares' }, '#board tbody tr:first-child'];
const resident = [{ role: 'cell', name: 'Island resident' }, '#resident'];
const proof = [{ role: 'cell', name: 'Proof of address required' }, '#fares tr:last-child td:last-child'];
export default {
  base: `http://127.0.0.1:${process.env.PORT || 7744}`,
  out: fileURLToPath(new URL('./takes/', import.meta.url)),
  compose: './draft.config.json',
  chapters: [
    { name: 'late', beats: [
      { name: 'board', goto: '/board', expectPath: '/board', ready: { role: 'table' } },
      { name: 'next', zoom: { on: '#next', scale: 2.2, ms: 800 }, mark: { label: 'The 14:20 runs late', on: '#next' }, hold: 1800 },
      { name: 'row', zoom: { on: lateRow, scale: 1.1, ms: 800 }, mark: { label: 'Flagged on the board too', on: lateRow }, hold: 1800 },
      { name: 'out', wide: 700, hold: 500 },
    ] },
    { name: 'resident', beats: [
      { name: 'board', goto: '/board', expectPath: '/board', ready: { role: 'table' } },
      { name: 'to-fares', click: [{ role: 'link', name: 'Fares', in: { role: 'navigation' } }, 'header nav >> text=Fares'], expectPath: '/fares', ready: [{ role: 'table' }, '#fares'] },
      { name: 'resident', zoom: { on: resident, scale: 2.2, ms: 800 }, mark: { label: 'Residents pay £2.10 a single', on: resident }, hold: 1800 },
      { name: 'proof', zoom: { on: proof, scale: 2.2, ms: 800 }, mark: { label: 'Proof of address needed', on: proof }, hold: 1800 },
      { name: 'out', wide: 700, hold: 500 },
    ] },
  ],
};
