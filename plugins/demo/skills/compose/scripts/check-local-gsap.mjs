#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { GSAP_FILE, GSAP_SHA256, GSAP_CDN, localGsapScript } from './gsap.mjs';
import { createHash } from 'node:crypto';

const project = process.argv[2];
if (!project) {
  console.error('usage: check-local-gsap.mjs <generated-project-dir>');
  process.exit(2);
}
const dir = resolve(project);
const html = readFileSync(`${dir}/index.html`, 'utf8');
const local = `${dir}/${GSAP_FILE}`;
if (html.includes(GSAP_CDN) || !html.includes(localGsapScript())) throw new Error(`${dir}: index.html does not load local ${GSAP_FILE}`);
if (!existsSync(local)) throw new Error(`${dir}: ${GSAP_FILE} is missing`);
const actual = createHash('sha256').update(readFileSync(local)).digest('hex');
if (actual !== GSAP_SHA256) throw new Error(`${dir}: ${GSAP_FILE} SHA-256 mismatch`);
console.log(`GSAP local check passed: ${dir}`);
