#!/usr/bin/env node
// Sends a text message to a SINCH_PUSH identity through the Conversation API.
//
//   npm run send-test-push -- <userId> ["message text"] [--dry-run]
//
// <userId> is the user id shown in the app (the one passed to setIdentity).
// Credentials come from .env (see .env.example) or the environment: an access
// key (SINCH_KEY_ID + SINCH_KEY_SECRET, exchanged for an OAuth2 bearer token) or
// a ready-made SINCH_ACCESS_TOKEN.
//
// The Conversation API app (SINCH_APP_ID) must have the Sinch Push channel
// enabled (contact Sinch / check the dashboard), or the call fails with 400/403.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const envFile = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && !line.trim().startsWith('#') && process.env[m[1]] === undefined) {
      const quoted = m[2].match(/^(['"])(.*)\1$/);
      // Unquoted values may carry a trailing `# comment`; an empty value counts as unset.
      const value = quoted ? quoted[2] : m[2].replace(/\s+#.*$/, '');
      if (value !== '') process.env[m[1]] = value;
    }
  }
}

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const [userId, text = `Hello from the Sinch Push example (${new Date().toISOString()})`] = args.filter(
  a => a !== '--dry-run',
);
const {SINCH_REGION: region = 'eu', SINCH_PROJECT_ID: projectId, SINCH_APP_ID: appId} = process.env;
const {SINCH_KEY_ID: keyId, SINCH_KEY_SECRET: keySecret, SINCH_ACCESS_TOKEN: accessToken} = process.env;

const problems = [];
if (!userId) problems.push('missing <userId> argument');
if (!['us', 'eu', 'br'].includes(region)) problems.push('SINCH_REGION must be us, eu or br');
if (!projectId) problems.push('SINCH_PROJECT_ID is not set');
if (!appId) problems.push('SINCH_APP_ID is not set');
if (!accessToken && !(keyId && keySecret)) problems.push('set SINCH_ACCESS_TOKEN or SINCH_KEY_ID + SINCH_KEY_SECRET');
if (problems.length) {
  console.error(`${problems.map(p => `- ${p}`).join('\n')}\n\nUsage: npm run send-test-push -- <userId> ["text"] [--dry-run]  (credentials: .env, see .env.example)`);
  process.exit(1);
}

const url = `https://${region}.conversation.api.sinch.com/v1/projects/${projectId}/messages:send`;
const body = {
  app_id: appId,
  recipient: {identified_by: {channel_identities: [{channel: 'SINCH_PUSH', identity: userId}]}},
  channel_priority_order: ['SINCH_PUSH'],
  message: {text_message: {text}},
};

// OAuth2 client-credentials: the access key id/secret are the client id/secret.
const TOKEN_URL = 'https://auth.sinch.com/oauth2/token';
async function fetchAccessToken() {
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: `Basic ${Buffer.from(`${keyId}:${keySecret}`).toString('base64')}`,
    },
    body: new URLSearchParams({grant_type: 'client_credentials'}),
  });
  const text = await response.text();
  let token;
  try {
    token = JSON.parse(text).access_token;
  } catch {}
  if (!response.ok || !token) {
    console.error(`Could not get an OAuth2 token (HTTP ${response.status} from ${TOKEN_URL}): check SINCH_KEY_ID / SINCH_KEY_SECRET.\n${text}`);
    process.exit(1);
  }
  return token;
}

console.log(`POST ${url}\n${JSON.stringify(body, null, 2)}`);
if (dryRun) {
  console.log(accessToken ? '\n(dry run) would send Authorization: Bearer $SINCH_ACCESS_TOKEN' : `\n(dry run) would POST ${TOKEN_URL} (grant_type=client_credentials, Basic key id:secret) and send the returned token as Authorization: Bearer`);
  process.exit(0);
}
const authorization = `Bearer ${accessToken || (await fetchAccessToken())}`;

const response = await fetch(url, {
  method: 'POST',
  headers: {'Content-Type': 'application/json', Authorization: authorization},
  body: JSON.stringify(body),
});
console.log(`\nHTTP ${response.status}\n${await response.text()}`);
process.exit(response.ok ? 0 : 1);
