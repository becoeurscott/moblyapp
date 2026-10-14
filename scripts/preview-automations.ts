/**
 * Lists the automated notifications the next pass would send, without
 * sending or recording anything. Usage: npx tsx scripts/preview-automations.ts
 */
import { previewAutomations } from '../src/services/automations';
import { prisma } from '../src/lib/prisma';

(async () => {
  const rows = await previewAutomations();
  const byType = new Map<string, number>();
  for (const r of rows) byType.set(r.type, (byType.get(r.type) ?? 0) + 1);
  console.log(`${rows.length} notification(s) would be sent`, Object.fromEntries(byType));
  for (const r of rows.slice(0, 40)) console.log(`- [${r.type}] ${r.title} — ${r.body}`);
  await prisma.$disconnect();
})();
