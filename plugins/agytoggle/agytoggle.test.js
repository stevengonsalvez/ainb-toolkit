import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const AGYTOGGLE_BIN = join(__dirname, 'agytoggle.js');

function makeTempHarness() {
  const tempDir = mkdtempSync(join(tmpdir(), 'agytoggle-test-'));
  const accountsPath = join(tempDir, 'antigravity-accounts.json');
  const tokenPath = join(tempDir, 'antigravity-oauth-token');

  const run = (args, options = {}) => {
    return execFileSync(process.execPath, [AGYTOGGLE_BIN, ...args], {
      env: {
        ...process.env,
        AGYTOGGLE_ACCOUNTS_PATH: accountsPath,
        AGYTOGGLE_TOKEN_PATH: tokenPath,
        PATH: process.env.PATH
      },
      encoding: 'utf8',
      ...options
    });
  };

  const cleanup = () => {
    rmSync(tempDir, { recursive: true, force: true });
  };

  return { tempDir, accountsPath, tokenPath, run, cleanup };
}

test('agytoggle help output', () => {
  const { run, cleanup } = makeTempHarness();
  try {
    const out = run(['help']);
    assert.match(out, /Antigravity CLI Multi-Account Switcher \(agytoggle\)/);
    assert.match(out, /agytoggle import/);
    assert.match(out, /agytoggle login/);
    assert.match(out, /agytoggle rotate/);
  } finally {
    cleanup();
  }
});

test('agytoggle import and list active profile', () => {
  const { run, tokenPath, accountsPath, cleanup } = makeTempHarness();
  try {
    const fakeToken = {
      token: {
        access_token: 'fake-access-token',
        token_type: 'Bearer',
        refresh_token: 'fake-refresh-token',
        expiry: new Date(Date.now() + 3600000).toISOString()
      },
      auth_method: 'consumer',
      id_token: `header.${Buffer.from(JSON.stringify({ email: 'test-user@domain.com' })).toString('base64')}.sig`
    };
    writeFileSync(tokenPath, JSON.stringify(fakeToken, null, 2), { mode: 0o600 });

    const importOut = run(['import']);
    assert.match(importOut, /test-user@domain\.com/);

    const listOut = run(['list']);
    assert.match(listOut, /1\. test-user@domain\.com ★ ACTIVE/);

    const currentOut = run(['current']);
    assert.match(currentOut, /Active: 1\. test-user@domain\.com/);

    const accountsData = JSON.parse(readFileSync(accountsPath, 'utf8'));
    assert.equal(accountsData.accounts.length, 1);
    assert.equal(accountsData.accounts[0].email, 'test-user@domain.com');
  } finally {
    cleanup();
  }
});

test('agytoggle strategy management', () => {
  const { run, accountsPath, cleanup } = makeTempHarness();
  try {
    writeFileSync(accountsPath, JSON.stringify({ accounts: [{ email: 'u1@test.com', refreshToken: 'tok' }], activeIndex: 0 }));
    
    let out = run(['strategy']);
    assert.match(out, /Current strategy: round-robin/);

    run(['strategy', 'sticky']);
    out = run(['strategy']);
    assert.match(out, /Current strategy: sticky/);

    const accountsData = JSON.parse(readFileSync(accountsPath, 'utf8'));
    assert.equal(accountsData.rotateStrategy, 'sticky');
  } finally {
    cleanup();
  }
});

test('agytoggle remove profile', () => {
  const { run, accountsPath, cleanup } = makeTempHarness();
  try {
    writeFileSync(accountsPath, JSON.stringify({
      accounts: [
        { email: 'u1@test.com', refreshToken: 'tok1' },
        { email: 'u2@test.com', refreshToken: 'tok2' }
      ],
      activeIndex: 0
    }));

    const removeOut = run(['remove', 'u1@test.com']);
    assert.match(removeOut, /Removed account: u1@test\.com/);

    const listOut = run(['list']);
    assert.doesNotMatch(listOut, /u1@test\.com/);
    assert.match(listOut, /u2@test\.com/);
  } finally {
    cleanup();
  }
});

test('agytoggle cooldown marks account with cooldownUntil', () => {
  const { run, accountsPath, cleanup } = makeTempHarness();
  try {
    writeFileSync(accountsPath, JSON.stringify({
      accounts: [
        { email: 'u1@test.com', refreshToken: 'tok1' },
        { email: 'u2@test.com', refreshToken: 'tok2' }
      ],
      activeIndex: 0
    }));

    try {
      run(['cooldown', '2']);
    } catch (err) {
      // Expected since fake refresh token cannot reach Google API
    }

    const accountsData = JSON.parse(readFileSync(accountsPath, 'utf8'));
    assert.ok(accountsData.accounts[0].cooldownUntil > Date.now());
  } finally {
    cleanup();
  }
});

test('agytoggle add validates token against Google OAuth API', () => {
  const { run, cleanup } = makeTempHarness();
  try {
    assert.throws(() => {
      run(['add', 'bad@test.com', 'invalid_token']);
    });
  } finally {
    cleanup();
  }
});

test('agytoggle auth-url prints single-line OAuth URL', () => {
  const { run, cleanup } = makeTempHarness();
  try {
    const urlOut = run(['auth-url', '8085']).trim();
    assert.match(urlOut, /^https:\/\/accounts\.google\.com\/o\/oauth2\/v2\/auth\?/);
    assert.match(urlOut, /redirect_uri=http%3A%2F%2Flocalhost%3A8085%2Fauth%2Fcallback/);
    assert.doesNotMatch(urlOut, /\s/);
  } finally {
    cleanup();
  }
});

test('agytoggle code validates input and handles errors', () => {
  const { run, cleanup } = makeTempHarness();
  try {
    assert.throws(() => {
      run(['code']);
    });
    assert.throws(() => {
      run(['code', 'http://localhost:8085/auth/callback?code=bad_test_code']);
    });
  } finally {
    cleanup();
  }
});

test('agytoggle copy-url outputs success and escape sequence', () => {
  const { run, cleanup } = makeTempHarness();
  try {
    const out = run(['copy-url', '8085']);
    assert.match(out, /Copied OAuth URL to clipboard/);
  } finally {
    cleanup();
  }
});


