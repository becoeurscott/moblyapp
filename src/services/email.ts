import { env } from '../config/env';
import { ApiError } from '../lib/http';

/**
 * Transactional mail through InsForge (AWS SES behind it). No SMTP and no
 * provider SDK: one authenticated POST with the project admin key.
 *
 * The plan caps sends per hour (10–50 depending on tier), so callers must keep
 * their own per-user cooldowns — this layer only reports the platform's 429.
 */
export function emailConfigured(): boolean {
  return env.insforge.emailConfigured;
}

export async function sendEmail(to: string, subject: string, html: string): Promise<void> {
  if (!emailConfigured()) {
    console.error('[email] INSFORGE_API_KEY not set — no mail sent to', maskEmail(to));
    throw new ApiError(503, 'Service e-mail indisponible', 'INTERNAL');
  }

  let res: Response;
  try {
    res = await fetch(`${env.insforge.url}/api/email/send-raw`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.insforge.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ to, subject, html, from: 'Mobly' }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    console.error('[email] request failed', { to: maskEmail(to), err: String(err) });
    throw new ApiError(503, 'Service e-mail indisponible', 'INTERNAL');
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    console.error('[email] send rejected', { to: maskEmail(to), status: res.status, body: body.slice(0, 300) });
    if (res.status === 429) {
      throw new ApiError(
        429,
        'Trop d’e-mails envoyés pour le moment. Réessayez dans quelques minutes.',
        'RATE_LIMITED'
      );
    }
    throw new ApiError(503, 'Service e-mail indisponible', 'INTERNAL');
  }
}

/** "scott.becoeur@gmail.com" -> "sc•••••••••@gmail.com" — recognisable, not harvestable. */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf('@');
  if (at < 1) return '•••';
  const local = email.slice(0, at);
  const keep = local.length <= 2 ? 1 : 2;
  return `${local.slice(0, keep)}${'•'.repeat(Math.max(3, local.length - keep))}${email.slice(at)}`;
}

/** Minimal, inline-styled HTML — mail clients ignore <style> blocks. */
export function codeEmailHtml(heading: string, intro: string, code: string, ttlMinutes: number): string {
  const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
  return `<!doctype html><html><body style="margin:0;padding:24px;background:#f4f5f8;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1c1d26">
<div style="max-width:440px;margin:0 auto;background:#ffffff;border-radius:16px;padding:28px">
<div style="font-size:22px;font-weight:700;color:#3a4ff0;margin-bottom:18px">mobly</div>
<h1 style="font-size:19px;margin:0 0 10px">${esc(heading)}</h1>
<p style="font-size:14px;line-height:1.5;color:#55586a;margin:0 0 20px">${esc(intro)}</p>
<div style="font-size:32px;font-weight:700;letter-spacing:8px;text-align:center;background:#f0f2ff;border-radius:12px;padding:16px 0;color:#1c1d26">${esc(code)}</div>
<p style="font-size:12.5px;line-height:1.5;color:#9a9dac;margin:20px 0 0">Ce code expire dans ${ttlMinutes} minutes. Si vous n’êtes pas à l’origine de cette demande, ignorez cet e-mail : votre compte reste protégé.</p>
</div></body></html>`;
}
