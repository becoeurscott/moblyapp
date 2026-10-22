import { Router, type Response } from 'express';
import { LEGAL_UPDATED, LEGAL_VERSION, confidentialite, cgu, legalGroups, type LegalDoc } from './docs';

/**
 * Public, unauthenticated HTML pages for the App Store listing (privacy policy,
 * terms, support). Same text as the in-app legal screens (generated from
 * Mobly/Models/LegalDocs.swift). No scripts, inline styles only.
 */

const SUPPORT_EMAIL = 'lamerique62@gmail.com';
const SUPPORT_PHONE = '+12149303696';

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const CSS = `
:root{--blue:#2F54EB;--ink:#111827;--muted:#6B7280;--line:#E5E7EB;--bg:#F7F8FC}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-text-size-adjust:100%}
header{background:var(--blue);color:#fff;padding:20px 16px}
header .in,main{max-width:760px;margin:0 auto}
header a{color:#fff;text-decoration:none;font-weight:700;font-size:20px;letter-spacing:.3px}
main{padding:24px 16px 48px}
h1{font-size:26px;line-height:1.25;margin:0 0 6px}
.meta{color:var(--muted);font-size:14px;margin:0 0 20px}
.intro{background:#fff;border:1px solid var(--line);border-left:4px solid var(--blue);border-radius:10px;padding:14px 16px}
h2{font-size:18px;margin:28px 0 8px;color:var(--blue)}
ul{padding-left:22px}li{margin:4px 0}
a{color:var(--blue)}
nav.toc{margin:20px 0;font-size:15px}nav.toc a{display:inline-block;margin:0 12px 6px 0}
.card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:16px;margin:12px 0}
footer{max-width:760px;margin:0 auto;padding:0 16px 32px;color:var(--muted);font-size:13px}
footer a{margin-right:12px}
`;

function page(title: string, content: string) {
  return `<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Mobly</title>
<style>${CSS}</style></head>
<body><header><div class="in"><a href="/support">Mobly</a></div></header>
<main>${content}</main>
<footer><a href="/legal/privacy">Confidentialité</a><a href="/legal/terms">CGU</a><a href="/legal">Documents légaux</a><a href="/support">Support</a></footer>
</body></html>`;
}

function renderDoc(doc: LegalDoc) {
  const sections = doc.sections
    .map(
      (s) =>
        `<h2>${esc(s.heading)}</h2>` +
        (s.body ?? []).map((p) => `<p>${esc(p)}</p>`).join('') +
        ((s.bullets ?? []).length ? `<ul>${s.bullets!.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>` : '')
    )
    .join('');
  return page(
    doc.title,
    `<h1>${esc(doc.title)}</h1><p class="meta">Version ${esc(LEGAL_VERSION)} · en vigueur depuis le ${esc(LEGAL_UPDATED)}</p>` +
      `<p class="intro">${esc(doc.intro)}</p>${sections}`
  );
}

function send(res: Response, html: string) {
  res.set('Cache-Control', 'public, max-age=3600');
  res.type('html').send(html);
}

const allDocs = legalGroups.flatMap((g) => g.docs);

export const legalPages = Router();

legalPages.get('/legal/privacy', (_req, res) => send(res, renderDoc(confidentialite)));
legalPages.get('/legal/terms', (_req, res) => send(res, renderDoc(cgu)));
legalPages.get('/legal', (_req, res) =>
  send(
    res,
    page(
      'Documents légaux',
      `<h1>Documents légaux</h1><p class="meta">Version ${esc(LEGAL_VERSION)} · ${esc(LEGAL_UPDATED)}</p>` +
        legalGroups
          .map(
            (g) =>
              `<h2>${esc(g.title)}</h2><ul>${g.docs
                .map((d) => `<li><a href="/legal/${esc(d.id)}">${esc(d.title)}</a> — ${esc(d.summary)}</li>`)
                .join('')}</ul>`
          )
          .join('')
    )
  )
);
legalPages.get('/legal/:id', (req, res, next) => {
  const doc = allDocs.find((d) => d.id === req.params.id);
  if (!doc) return next();
  send(res, renderDoc(doc));
});

legalPages.get('/support', (_req, res) =>
  send(
    res,
    page(
      'Support',
      `<h1>Support Mobly</h1>
<p class="intro">Une question, un problème avec une annonce, une visite ou votre compte ? L'équipe Mobly vous répond.<br><em>Need help? Contact the Mobly team using any of the options below.</em></p>
<div class="card"><h2>Dans l'application</h2><p>Depuis votre <strong>Profil</strong>, touchez <strong>Contacter le support</strong> pour discuter directement avec le Support Mobly. C'est le moyen le plus rapide.</p></div>
<div class="card"><h2>Par e-mail</h2><p><a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p></div>
<div class="card"><h2>Par téléphone</h2><p><a href="tel:${SUPPORT_PHONE}">${SUPPORT_PHONE}</a></p></div>
<div class="card"><h2>Signaler un contenu</h2><p>Utilisez le bouton de signalement présent sur une annonce, une conversation ou un profil. Les signalements sont examinés par l'équipe de modération.</p></div>
<div class="card"><h2>Supprimer votre compte</h2><p>Depuis l'application, dans votre profil : <strong>Supprimer mon compte</strong>. Vous pouvez aussi en faire la demande par e-mail.</p></div>
<p><a href="/legal/privacy">Politique de confidentialité</a> · <a href="/legal/terms">Conditions Générales d'Utilisation</a> · <a href="/legal">Tous les documents légaux</a></p>`
    )
  )
);
