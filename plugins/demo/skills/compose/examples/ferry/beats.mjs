// Beats for the Skerry Ferries example. Start the app first: node serve.mjs
// Takes land in ./takes next to this file, which is where ferry.config.json looks for them.
import { fileURLToPath } from 'node:url';
const nav = 'header nav';
export default {
  base: `http://127.0.0.1:${process.env.PORT || 7744}`,
  out: fileURLToPath(new URL('./takes/', import.meta.url)),
  viewport: { width: 1280, height: 720 },
  chapters: [
    { name: 'departures', beats: [
      { name: 'land', goto: '/board', expectPath: '/board', ready: '#board', hold: 1200 },
      { zoom: { on: '#next', scale: 2.2, ms: 800 }, mark: { label: 'Next sailing runs late', on: '#next' }, hold: 1600 },
      { zoom: { on: '#cap', scale: 2.2, ms: 700 }, mark: { label: 'Six car spaces left', on: '#cap' }, hold: 1600 },
      { wide: 700, hold: 500 },
      { zoom: { on: '#board', scale: 1.5, ms: 800 }, mark: { label: 'Four sailings, status each', on: '#board' }, hold: 1800 },
      { wide: 700, hold: 800 },
    ] },
    { name: 'fares', beats: [
      { name: 'land', goto: '/board', expectPath: '/board', ready: '#board', hold: 900 },
      { name: 'to-fares', click: `${nav} >> text=Fares`, expectPath: '/fares', ready: '#fares', hold: 1400 },
      { zoom: { on: '#fares', scale: 1.5, ms: 800 }, mark: { label: 'Single and return per ticket', on: '#fares' }, hold: 1800 },
      { zoom: { on: '#resident', scale: 2.4, ms: 800 }, mark: { label: 'Resident fare needs proof', on: '#resident' }, hold: 1700 },
      { wide: 700, hold: 800 },
    ] },
  ],
};
