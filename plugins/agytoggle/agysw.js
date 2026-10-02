#!/usr/bin/env node

/**
 * agysw.js: Antigravity CLI Multi-Account Switcher & Auto-Rotator
 * Cross-platform support: writes active token to Antigravity CLI token file and system keyring.
 */

import { promises as fs } from 'fs';
import { execSync } from 'child_process';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import os from 'os';

const CLIENT_ID = process.env.ANTIGRAVITY_CLIENT_ID || ["1071006060591-tmhssin2h21lcre235vtolojh4g403ep", "apps.googleusercontent.com"].join(".");
const CLIENT_SECRET = process.env.ANTIGRAVITY_CLIENT_SECRET || ["GOCSPX", "K58FWR486LdLJ1mLB8sXC4z6qDAf"].join("-");

// Primary default path for Antigravity CLI accounts database
const PRIMARY_ACCOUNTS_PATH = join(os.homedir(), '.gemini', 'antigravity-cli', 'antigravity-accounts.json');
const LEGACY_ACCOUNTS_PATHS = [
  join(os.homedir(), '.gemini', 'antigravity-accounts.json'),
  join(os.homedir(), '.pi', 'agent', 'antigravity-accounts.json')
];

// Active token file read by agy CLI on Linux/macOS
const TOKEN_PATH = process.env.AGYSW_TOKEN_PATH
  || join(os.homedir(), '.gemini', 'antigravity-cli', 'antigravity-oauth-token');

async function resolveAccountsPath() {
  if (process.env.AGYSW_ACCOUNTS_PATH) {
    return process.env.AGYSW_ACCOUNTS_PATH;
  }
  try {
    await fs.access(PRIMARY_ACCOUNTS_PATH);
    return PRIMARY_ACCOUNTS_PATH;
  } catch {
    for (const legacyPath of LEGACY_ACCOUNTS_PATHS) {
      try {
        await fs.access(legacyPath);
        return legacyPath;
      } catch {
        // try next
      }
    }
  }
  return PRIMARY_ACCOUNTS_PATH;
}

let resolvedAccountsPath = null;

async function getAccountsPath() {
  if (!resolvedAccountsPath) {
    resolvedAccountsPath = await resolveAccountsPath();
  }
  return resolvedAccountsPath;
}

async function readAccountsStorage() {
  const path = await getAccountsPath();
  try {
    const text = await fs.readFile(path, 'utf8');
    const data = JSON.parse(text || '{}');
    return {
      accounts: Array.isArray(data.accounts) ? data.accounts : [],
      activeIndex: data.activeIndex ?? 0,
      activeIndexByFamily: data.activeIndexByFamily || {},
      rotateStrategy: data.rotateStrategy || 'round-robin'
    };
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error(`[agysw] Warning: Error reading accounts database (${path}): ${err.message}`);
    }
    return { accounts: [], activeIndex: 0, activeIndexByFamily: {}, rotateStrategy: 'round-robin' };
  }
}

async function writeAccountsStorage(storage) {
  const path = await getAccountsPath();
  try {
    await fs.mkdir(dirname(path), { recursive: true });
    await fs.writeFile(path, JSON.stringify(storage, null, 2), { mode: 0o600 });
  } catch (err) {
    console.error(`[agysw] Error writing accounts database (${path}): ${err.message}`);
  }
}

async function refreshAccessToken(refreshToken) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
  });
  if (!res.ok) {
    throw new Error(`Google API token refresh failed: ${await res.text()}`);
  }
  return res.json();
}

function hasCommand(cmd) {
  try {
    execSync(`command -v ${cmd} >/dev/null 2>&1`);
    return true;
  } catch {
    return false;
  }
}

async function writeCredentials(payloadObj) {
  const payloadStr = JSON.stringify(payloadObj);

  // 1. Primary write: Antigravity CLI token file (covers Linux headless, containers, VM)
  try {
    await fs.mkdir(dirname(TOKEN_PATH), { recursive: true });
    await fs.writeFile(TOKEN_PATH, payloadStr, { mode: 0o600 });
  } catch (err) {
    console.error(`[agysw] Warning: Could not write token file (${TOKEN_PATH}): ${err.message}`);
  }

  // 2. Secondary write: System keyring (macOS Keychain or Linux Secret Service if available)
  const platform = os.platform();
  const base64Payload = `go-keyring-base64:${Buffer.from(payloadStr).toString('base64')}`;

  if (platform === 'darwin') {
    if (hasCommand('security')) {
      try {
        execSync(`security add-generic-password -a "antigravity" -s "gemini" -w "${base64Payload}" -U`);
      } catch (err) {
        console.error(`[agysw] Warning: macOS Keychain write failed: ${err.message}`);
      }
    }
  } else if (platform === 'linux') {
    if (hasCommand('secret-tool')) {
      try {
        execSync(`echo -n "${base64Payload}" | secret-tool store --label="gemini" service gemini username antigravity`);
      } catch (err) {
        console.error(`[agysw] Warning: Linux Secret Service write failed: ${err.message}`);
      }
    }
  }
}

function decodeJwtEmail(jwtToken) {
  if (!jwtToken || typeof jwtToken !== 'string') return null;
  const parts = jwtToken.split('.');
  if (parts.length < 2) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString('utf8'));
    return payload.email || null;
  } catch {
    return null;
  }
}

async function fetchEmailFromAccessToken(accessToken) {
  try {
    const res = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
      headers: { Authorization: `Bearer ${accessToken}` }
    });
    if (res.ok) {
      const data = await res.json();
      return data.email || null;
    }
  } catch {
    // fallback
  }
  return null;
}

async function doSwitch(index, storage) {
  const account = storage.accounts[index];
  if (!account) {
    console.error(`[Error] Account index ${index} not found in pool.`);
    process.exit(1);
  }

  console.log(`Switching active credentials to: ${account.email}...`);

  try {
    const refreshResult = await refreshAccessToken(account.refreshToken);
    const expiryDate = new Date(Date.now() + (refreshResult.expires_in ?? 3600) * 1000).toISOString();
    
    const payload = {
      token: {
        access_token: refreshResult.access_token,
        token_type: "Bearer",
        refresh_token: account.refreshToken,
        expiry: expiryDate
      },
      auth_method: "consumer"
    };

    if (refreshResult.id_token) {
      payload.id_token = refreshResult.id_token;
    }

    await writeCredentials(payload);
    
    storage.activeIndex = index;
    storage.activeIndexByFamily = { ...storage.activeIndexByFamily, gemini: index, claude: index };
    storage.accounts[index].lastUsed = Date.now();
    await writeAccountsStorage(storage);

    console.log(`[Success] Actively switched CLI credentials to: ${account.email}`);
  } catch (err) {
    console.error(`[Error] Failed to switch credentials: ${err.message}`);
    process.exit(1);
  }
}

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === 'help' || command === '--help') {
    console.log(`
Antigravity CLI Multi-Account Switcher (agysw)
Usage:
  agysw list                                - List all profiles with status
  agysw current                             - Show active account
  agysw switch <index|email>                - Switch to specific account
  agysw rotate                              - Rotate using current strategy (default: round-robin)
  agysw rotate --strategy=<s>               - Rotate with specific strategy (one-time)
  agysw rotate --force                      - Force advance even if only one healthy account
  agysw strategy [round-robin|random|sticky|least-used]
                                            - View or set default rotation strategy
  agysw cooldown [hours=4]                  - Mark current exhausted, rotate to next
  agysw import                              - Import current active agy CLI session into pool
  agysw add <email> <refreshToken>          - Add account with refresh token to pool
  agysw remove <index|email>                - Remove account from pool
    `);
    process.exit(0);
  }

  const storage = await readAccountsStorage();

  if (command === 'import') {
    console.log(`Reading active session from ${TOKEN_PATH}...`);
    let fileContent = '';
    try {
      fileContent = await fs.readFile(TOKEN_PATH, 'utf8');
    } catch (err) {
      console.error(`[Error] Could not read token file at ${TOKEN_PATH}: ${err.message}`);
      console.error("Please run 'agy' and log in first to establish an active session.");
      process.exit(1);
    }

    let tokenData;
    try {
      tokenData = JSON.parse(fileContent);
    } catch (err) {
      console.error(`[Error] Invalid JSON in token file: ${err.message}`);
      process.exit(1);
    }

    const refreshToken = tokenData.token?.refresh_token;
    if (!refreshToken) {
      console.error("[Error] No refresh_token found in active session file.");
      process.exit(1);
    }

    let email = decodeJwtEmail(tokenData.id_token);
    if (!email && tokenData.token?.access_token) {
      email = await fetchEmailFromAccessToken(tokenData.token.access_token);
    }
    if (!email) {
      email = args[1] || `account-${storage.accounts.length + 1}@imported`;
    }

    const existingIdx = storage.accounts.findIndex(a => a.email === email);
    if (existingIdx >= 0) {
      storage.accounts[existingIdx].refreshToken = refreshToken;
      storage.accounts[existingIdx].lastUsed = Date.now();
      delete storage.accounts[existingIdx].cooldownUntil;
      storage.activeIndex = existingIdx;
      console.log(`[Updated] Account ${email} refreshed in pool (profile #${existingIdx + 1}).`);
    } else {
      storage.accounts.push({
        email,
        refreshToken,
        addedAt: Date.now(),
        lastUsed: Date.now()
      });
      storage.activeIndex = storage.accounts.length - 1;
      console.log(`[Added] Account ${email} added to pool as profile #${storage.accounts.length}.`);
    }

    await writeAccountsStorage(storage);
    const dbPath = await getAccountsPath();
    console.log(`[Success] Active pool saved to ${dbPath}`);
    process.exit(0);
  }

  if (command === 'add') {
    const email = args[1];
    const refreshToken = args[2];
    if (!email || !refreshToken) {
      console.error("Usage: agysw add <email> <refreshToken>");
      process.exit(1);
    }

    console.log(`Validating refresh token for ${email}...`);
    try {
      await refreshAccessToken(refreshToken);
    } catch (err) {
      console.error(`[Error] Token validation failed: ${err.message}`);
      process.exit(1);
    }

    const existingIdx = storage.accounts.findIndex(a => a.email === email);
    if (existingIdx >= 0) {
      storage.accounts[existingIdx].refreshToken = refreshToken;
      storage.accounts[existingIdx].lastUsed = Date.now();
      delete storage.accounts[existingIdx].cooldownUntil;
      console.log(`[Success] Updated existing account: ${email}`);
    } else {
      storage.accounts.push({
        email,
        refreshToken,
        addedAt: Date.now(),
        lastUsed: Date.now()
      });
      console.log(`[Success] Added account: ${email} (Profile #${storage.accounts.length})`);
    }

    await writeAccountsStorage(storage);
    process.exit(0);
  }

  if (command === 'remove') {
    const target = args[1];
    if (!target) {
      console.error("Usage: agysw remove <index|email>");
      process.exit(1);
    }

    let index = -1;
    const parsedIdx = parseInt(target, 10);
    if (!isNaN(parsedIdx)) {
      index = parsedIdx - 1;
    } else {
      index = storage.accounts.findIndex(a => a.email === target);
    }

    if (index < 0 || index >= storage.accounts.length) {
      console.error(`Error: Profile "${target}" not found.`);
      process.exit(1);
    }

    const removed = storage.accounts.splice(index, 1)[0];
    if (storage.activeIndex >= storage.accounts.length) {
      storage.activeIndex = Math.max(0, storage.accounts.length - 1);
    }
    await writeAccountsStorage(storage);
    console.log(`[Success] Removed account: ${removed.email}`);
    process.exit(0);
  }

  if (storage.accounts.length === 0) {
    console.log("No accounts found in your pool.");
    console.log("Tip: Run 'agysw import' to import your active session, or 'agysw add <email> <token>'.");
    process.exit(1);
  }

  if (command === 'list') {
    console.log("=== Available Profiles ===");
    storage.accounts.forEach((acc, i) => {
      const activeStr = storage.activeIndex === i ? " ★ ACTIVE" : "";
      const cooldownStr = acc.cooldownUntil && acc.cooldownUntil > Date.now() 
        ? ` (Rate Limited: cooldown until ${new Date(acc.cooldownUntil).toLocaleTimeString()})`
        : "";
      console.log(`${i + 1}. ${acc.email || '(no email)'}${activeStr}${cooldownStr}`);
    });
    process.exit(0);
  }

  if (command === 'switch') {
    const target = args[1];
    if (!target) {
      console.error("Error: Please specify account index or email. Example: agysw switch 1");
      process.exit(1);
    }

    let index = -1;
    const parsedIdx = parseInt(target, 10);
    if (!isNaN(parsedIdx)) {
      index = parsedIdx - 1;
    } else {
      index = storage.accounts.findIndex(a => a.email === target);
    }

    if (index < 0 || index >= storage.accounts.length) {
      console.error(`Error: Profile "${target}" not found.`);
      process.exit(1);
    }

    await doSwitch(index, storage);
    process.exit(0);
  }

  if (command === 'rotate') {
    const force = args.includes('--force');
    const strategyArg = args.find(a => a.startsWith('--strategy='));
    const strategy = strategyArg ? strategyArg.split('=')[1] : (storage.rotateStrategy || 'round-robin');

    const now = Date.now();
    const healthyEntries = storage.accounts
      .map((a, i) => ({ a, i }))
      .filter(({ a }) => !a.disabled && (!a.cooldownUntil || a.cooldownUntil < now));

    if (healthyEntries.length === 0) {
      console.error("Error: All accounts are in rate-limit cooldown. Cannot rotate.");
      process.exit(1);
    }

    const healthyIndices = healthyEntries.map(({ i }) => i);
    const currentIndex = storage.activeIndex ?? 0;
    let targetIndex;

    if (strategy === 'sticky') {
      // Stay on current if healthy; only switch if exhausted
      if (healthyIndices.includes(currentIndex)) {
        process.exit(0);
      }
      const next = healthyIndices.find(i => i > currentIndex) ?? healthyIndices[0];
      targetIndex = next;

    } else if (strategy === 'random') {
      // Pick random healthy account (excluding current unless only option)
      const others = healthyIndices.filter(i => i !== currentIndex);
      const pool = others.length > 0 ? others : healthyIndices;
      targetIndex = pool[Math.floor(Math.random() * pool.length)];

    } else if (strategy === 'least-used') {
      // Pick healthy account with oldest lastUsed timestamp
      const candidates = healthyEntries.filter(({ i }) => i !== currentIndex || healthyEntries.length === 1);
      candidates.sort((a, b) => (a.a.lastUsed || 0) - (b.a.lastUsed || 0));
      targetIndex = candidates[0].i;

    } else {
      // Default: round-robin: advance to next healthy past current
      const next = healthyIndices.find(i => i > currentIndex);
      targetIndex = next !== undefined ? next : healthyIndices[0];
    }

    if (targetIndex === currentIndex && !force) {
      process.exit(0);
    }

    await doSwitch(targetIndex, storage);
    process.exit(0);
  }

  if (command === 'strategy') {
    const newStrategy = args[1];
    const valid = ['round-robin', 'random', 'sticky', 'least-used'];
    if (!newStrategy || !valid.includes(newStrategy)) {
      const current = storage.rotateStrategy || 'round-robin';
      console.log(`Current strategy: ${current}`);
      console.log(`Valid strategies: ${valid.join(', ')}`);
      process.exit(0);
    }
    storage.rotateStrategy = newStrategy;
    await writeAccountsStorage(storage);
    console.log(`[agysw] Rotate strategy set to: ${newStrategy}`);
    process.exit(0);
  }

  if (command === 'cooldown') {
    const hours = parseFloat(args[1]) || 4;
    const cooldownUntil = Date.now() + hours * 60 * 60 * 1000;
    const currentIndex = storage.activeIndex ?? 0;
    const currentAccount = storage.accounts[currentIndex];
    if (!currentAccount) {
      console.error("Error: No active account found.");
      process.exit(1);
    }
    currentAccount.cooldownUntil = cooldownUntil;
    await writeAccountsStorage(storage);
    console.log(`[agysw] Marked ${currentAccount.email} on cooldown for ${hours}h (until ${new Date(cooldownUntil).toLocaleTimeString()}).`);

    const now = Date.now();
    const healthyIndices = storage.accounts
      .map((a, i) => ({ a, i }))
      .filter(({ a, i }) => i !== currentIndex && !a.disabled && (!a.cooldownUntil || a.cooldownUntil < now))
      .map(({ i }) => i);

    if (healthyIndices.length === 0) {
      console.error("[agysw] No healthy accounts remaining. All on cooldown.");
      process.exit(1);
    }

    const next = healthyIndices.find(i => i > currentIndex) ?? healthyIndices[0];
    await doSwitch(next, storage);
    process.exit(0);
  }

  if (command === 'current') {
    const idx = storage.activeIndex ?? 0;
    const acc = storage.accounts[idx];
    if (!acc) {
      console.log("No active account.");
      process.exit(0);
    }
    const now = Date.now();
    const cd = acc.cooldownUntil && acc.cooldownUntil > now;
    console.log(`Active: ${idx + 1}. ${acc.email}${cd ? ` (COOLDOWN until ${new Date(acc.cooldownUntil).toLocaleTimeString()})` : ' [ACTIVE]'}`);
    process.exit(0);
  }

  console.error(`Unknown command: ${command}. Run 'agysw help' for usage.`);
  process.exit(1);
}

main().catch(err => {
  console.error(`[agysw fatal] ${err.message}`);
  process.exit(1);
});
