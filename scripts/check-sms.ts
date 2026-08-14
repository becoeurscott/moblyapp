/**
 * Twilio configuration check.
 *
 *   npx tsx scripts/check-sms.ts                 # config + credentials only
 *   npx tsx scripts/check-sms.ts +237677123456   # also send one real SMS
 *
 * Never prints the auth token. Sending is opt-in via the argument so running
 * this by habit can't quietly spend money.
 */
import twilio from 'twilio';
import { env } from '../src/config/env';
import { isAllowedDestination } from '../src/services/sms';

function mask(value: string): string {
  if (!value) return '(vide)';
  return value.length <= 8 ? '****' : `${value.slice(0, 4)}…${value.slice(-4)}`;
}

async function main() {
  const target = process.argv[2];

  console.log('\n— Configuration —');
  console.log('  TWILIO_ACCOUNT_SID          :', mask(env.twilio.accountSid));
  console.log('  TWILIO_AUTH_TOKEN           :', env.twilio.authToken ? 'défini' : '(vide)');
  console.log('  TWILIO_API_KEY_SID          :', mask(env.twilio.apiKeySid));
  console.log('  TWILIO_API_KEY_SECRET       :', env.twilio.apiKeySecret ? 'défini' : '(vide)');
  console.log('  TWILIO_MESSAGING_SERVICE_SID:', mask(env.twilio.messagingServiceSid));
  console.log('  TWILIO_FROM_NUMBER          :', env.twilio.fromNumber || '(vide)');
  console.log('  SMS_ALLOWED_COUNTRIES       :', env.twilio.allowedPrefixes.join(', ') || '(tout — dangereux)');
  console.log('  configured                  :', env.twilio.configured ? 'oui' : 'NON');

  if (!env.twilio.configured) {
    console.error(
      '\n✗ Incomplet. Il faut :\n' +
        '  • TWILIO_ACCOUNT_SID\n' +
        '  • TWILIO_AUTH_TOKEN  OU  (TWILIO_API_KEY_SID + TWILIO_API_KEY_SECRET)\n' +
        '  • TWILIO_MESSAGING_SERVICE_SID  OU  TWILIO_FROM_NUMBER'
    );
    process.exit(1);
  }

  const { accountSid, authToken, apiKeySid, apiKeySecret } = env.twilio;
  const client = apiKeySid && apiKeySecret
    ? twilio(apiKeySid, apiKeySecret, { accountSid })
    : twilio(accountSid, authToken);
  console.log('  auth utilisée               :', apiKeySid ? 'API Key' : 'Auth Token');

  console.log('\n— Compte —');
  try {
    const account = await client.api.v2010.accounts(env.twilio.accountSid).fetch();
    console.log('  nom    :', account.friendlyName);
    console.log('  statut :', account.status);
    console.log('  type   :', account.type); // "Trial" only texts verified numbers
    if (account.type === 'Trial') {
      console.log(
        '  ⚠ Compte d’essai : seuls les numéros vérifiés dans la console Twilio\n' +
          '    peuvent recevoir un SMS.'
      );
    }
  } catch (err) {
    console.error('  ✗ Identifiants refusés :', (err as Error).message);
    process.exit(1);
  }

  if (env.twilio.messagingServiceSid) {
    try {
      const svc = await client.messaging.v1
        .services(env.twilio.messagingServiceSid)
        .fetch();
      console.log('\n— Messaging Service —');
      console.log('  nom :', svc.friendlyName);
    } catch (err) {
      console.error('\n  ✗ Messaging Service introuvable :', (err as Error).message);
      process.exit(1);
    }
  }

  try {
    const numbers = await client.incomingPhoneNumbers.list({ limit: 5 });
    console.log('\n— Numéros disponibles —');
    if (numbers.length === 0) {
      console.log('  (aucun) — achetez un numéro, ou utilisez un Messaging Service');
    } else {
      numbers.forEach((n) => console.log('  ', n.phoneNumber, '—', n.friendlyName));
    }
  } catch {
    // Non-fatal: an API Key may lack permission to list numbers.
  }

  if (!target) {
    console.log('\n✓ Configuration valide. Pour un envoi réel :');
    console.log('    npx tsx scripts/check-sms.ts +237677123456\n');
    return;
  }

  console.log('\n— Envoi de test —');
  if (!isAllowedDestination(target)) {
    console.error(
      `  ✗ ${target} est hors de SMS_ALLOWED_COUNTRIES — bloqué avant envoi.`
    );
    process.exit(1);
  }
  try {
    const msg = await client.messages.create({
      to: target,
      body: 'Test Mobly : la configuration SMS fonctionne.',
      ...(env.twilio.messagingServiceSid
        ? { messagingServiceSid: env.twilio.messagingServiceSid }
        : { from: env.twilio.fromNumber }),
    });
    console.log('  ✓ envoyé, SID :', msg.sid, '| statut :', msg.status);
  } catch (err) {
    const e = err as { code?: number; message?: string };
    console.error('  ✗ échec', e.code ? `(code ${e.code})` : '', ':', e.message);
    process.exit(1);
  }
}

main();
