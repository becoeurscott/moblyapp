/**
 * Chat-media retention job.
 *
 * Deletes image / voice files older than CHAT_MEDIA_RETENTION_DAYS from Supabase
 * Storage and marks the message as expired (mediaUrl cleared, mediaExpired=true).
 * Listing photos and avatars are untouched — they live on Cloudinary and are
 * permanent.
 *
 * Run daily as a Render Cron Job:
 *   node dist/scripts/cleanupChatMedia.js
 *
 * Safe to run repeatedly: already-expired rows are filtered out, and a delete
 * that fails (or points at a non-Supabase URL) still clears the row so the
 * bubble reads "expirée" rather than staying broken forever.
 */
import { prisma } from '../lib/prisma';
import { env } from '../config/env';
import { deleteChatMediaByUrl } from '../lib/supabaseStorage';

async function main() {
  const days = env.chatMediaRetentionDays;
  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);

  const stale = await prisma.message.findMany({
    where: {
      kind: { in: ['IMAGE', 'VOICE'] },
      mediaExpired: false,
      mediaUrl: { not: null },
      createdAt: { lt: cutoff },
    },
    select: { id: true, mediaUrl: true },
  });

  console.log(`[cleanupChatMedia] ${stale.length} item(s) older than ${days}d to expire`);

  let deleted = 0;
  for (const m of stale) {
    if (m.mediaUrl) await deleteChatMediaByUrl(m.mediaUrl);
    await prisma.message.update({
      where: { id: m.id },
      data: { mediaUrl: null, mediaExpired: true },
    });
    deleted += 1;
  }

  console.log(`[cleanupChatMedia] expired ${deleted} item(s)`);
}

main()
  .catch((e) => {
    console.error('[cleanupChatMedia] failed:', e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
