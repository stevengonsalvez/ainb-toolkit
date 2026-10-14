import { execFileSync } from 'node:child_process';
import { copyFileSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

export const GSAP_VERSION = '3.14.2';
export const GSAP_FILE = 'gsap.min.js';
export const GSAP_SHA256 = 'c174bfce53a729418d57a8ad8625e7247c793a22fef8e2851e3cfa3de9cd8280';
export const GSAP_CDN = `https://cdn.jsdelivr.net/npm/gsap@${GSAP_VERSION}/dist/${GSAP_FILE}`;
export const GSAP_SRI = 'sha384-sG0Hv1tP1lZCk9KQmrIbY/XNwi+OY84GQqhMscbnsoBFqAz8KNCil1kvfL3Hbbk2';
export const GSAP_SCRIPT_TOKEN = '<!-- GSAP_SCRIPT -->';
export const localGsapScript = () => `<script src="${GSAP_FILE}"></script>`;
export const cdnGsapScript = () => `<script src="${GSAP_CDN}" integrity="${GSAP_SRI}" crossorigin="anonymous"></script>`;

const hash = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');
const reason = (error) => String(error?.message || error).split('\n')[0];

// A generated project keeps the browser dependency beside index.html. The package is pinned in
// its template manifest; this install is intentionally done before rendering, not by the renderer.
export function installGsap(projectDir) {
  try {
    execFileSync('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false'], {
      cwd: projectDir,
      stdio: 'pipe',
    });
    const installed = join(projectDir, 'node_modules', 'gsap', 'dist', GSAP_FILE);
    const actual = hash(installed);
    if (actual !== GSAP_SHA256) throw new Error(`expected SHA-256 ${GSAP_SHA256}, got ${actual}`);
    copyFileSync(installed, join(projectDir, GSAP_FILE));
    console.info(`GSAP: installed and verified ${GSAP_VERSION} locally for ${projectDir}`);
    return localGsapScript();
  } catch (error) {
    console.warn(`GSAP: local install or integrity verification failed (${reason(error)}). Falling back to pinned CDN with SRI; this render needs network access.`);
    return cdnGsapScript();
  }
}
