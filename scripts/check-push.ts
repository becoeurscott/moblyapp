/**
 * Verify the APNs credentials, and optionally send a real notification.
 *
 *   npx tsx scripts/check-push.ts                # credentials only
 *   npx tsx scripts/check-push.ts <deviceToken>  # send a real push
 *
 * The credential check deliberately uses a bogus device token: Apple answers
 * `BadDeviceToken` when the *provider token* was accepted and only the device
 * is wrong, versus `InvalidProviderToken` / `Forbidden` when the key, key id
 * or team id is wrong. That distinction proves the signing works without
 * needing a real device.
 */
import { env } from '../src/config/env';
import { pushConfigured } from '../src/services/push';
import http2 from 'node:http2';
import { SignJWT, importPKCS8 } from 'jose';

function mask(v: string) {
  return v ? `${v.slice(0, 4)}…${v.slice(-2)}` : '(vide)';
}

async function main() {
  const target = process.argv[2];

  console.log('\n— Configuration —');
  console.log('  APNS_KEY_ID     :', mask(env.apns.keyId));
  console.log('  APNS_TEAM_ID    :', mask(env.apns.teamId));
  console.log('  APNS_BUNDLE_ID  :', env.apns.bundleId);
  console.log('  APNS_PRODUCTION :', env.apns.production, env.apns.production ? '(live gateway)' : '(sandbox — Xcode builds)');
  const key = env.apns.key;
  console.log('  clé .p8         :', key ? `chargée (${key.split('\n').length} lignes)` : 'MANQUANTE');
  console.log('  configured      :', pushConfigured() ? 'oui' : 'NON');

  if (!pushConfigured()) {
    console.error('\n✗ Incomplet — il faut APNS_KEY_ID, APNS_TEAM_ID et la clé.\n');
    process.exit(1);
  }

  let jwt: string;
  try {
    const pk = await importPKCS8(key.replace(/\\n/g, '\n'), 'ES256');
    jwt = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: env.apns.keyId })
      .setIssuer(env.apns.teamId)
      .setIssuedAt()
      .sign(pk);
    console.log('\n  ✓ clé lue et JWT ES256 signé');
  } catch (err) {
    console.error('\n  ✗ clé illisible :', (err as Error).message);
    process.exit(1);
  }

  const deviceToken = target ?? '0'.repeat(64);
  const host = env.apns.production
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';

  const body = JSON.stringify({
    aps: {
      alert: { title: 'Mobly', body: 'Test de notification ✅' },
      sound: 'default',
    },
    threadId: 'test',
  });

  console.log(`\n— Appel APNs (${env.apns.production ? 'production' : 'sandbox'}) —`);
  await new Promise<void>((resolve) => {
    const client = http2.connect(host);
    client.on('error', (e) => {
      console.error('  ✗ connexion échouée :', e.message);
      resolve();
    });
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': env.apns.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });
    let status = 0;
    let raw = '';
    req.on('response', (h) => (status = Number(h[':status'])));
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      client.close();
      const reason = raw ? (JSON.parse(raw).reason ?? '') : '';
      console.log(`  HTTP ${status} ${reason}`);

      if (status === 200) {
        console.log('  ✓ notification envoyée');
      } else if (reason === 'BadDeviceToken') {
        console.log('  ✓ IDENTIFIANTS VALIDES — Apple a accepté la clé,');
        console.log('    seul le token appareil est faux (attendu pour ce test).');
        if (!target) {
          console.log('\n    Pour un envoi réel :');
          console.log('      npx tsx scripts/check-push.ts <token-de-l-appareil>');
        }
      } else if (reason === 'InvalidProviderToken' || status === 403) {
        console.error('  ✗ clé / key id / team id refusés par Apple');
      } else if (reason === 'TopicDisallowed') {
        console.error(`  ✗ bundle id "${env.apns.bundleId}" non autorisé pour cette clé`);
      } else {
        console.error('  ✗ réponse inattendue :', raw);
      }
      resolve();
    });
    req.on('error', (e) => {
      console.error('  ✗ requête échouée :', e.message);
      resolve();
    });
    req.end(body);
  });
  console.log();
}

main();
