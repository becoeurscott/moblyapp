/**
 * Chat-media retention job.
 *
 * Deletes chat image / voice files older than CHAT_MEDIA_RETENTION_DAYS from
 * Cloudinary and marks the message as expired (mediaUrl cleared,
 * mediaExpired=true). Listing photos and avatars are permanent and untouched.
 *
 * Run daily as a Render Cron Job:
 *   node dist/scripts/cleanupChatMedia.js
 *
 * Safe to run repeatedly: already-expired rows are filtered out, and a delete
 * that fails (or points at a non-Cloudinary URL) still clears the row so the
 * bubble reads "expirée" rather than staying broken forever.
 */
import { v2 as cloudinary } from 'cloudinary';
import { prisma } from '../lib/prisma';
import { env } from '../config/env';

cloudinary.config({
  cloud_name: env.cloudinary.cloudName,
  api_key: env.cloudinary.apiKey,
  api_secret: env.cloudinary.apiSecret,
  secure: true,
});

/**
 * Pull the public_id and resource_type out of a Cloudinary delivery URL, e.g.
 *   https://res.cloudinary.com/<cloud>/image/upload/v123/mobly/chat/<uid>/ab.jpg
 *   → { resourceType: 'image', publicId: 'mobly/chat/<uid>/ab' }
 * Voice notes are delivered as `video` (Cloudinary's audio pipeline).
 * Returns null for anything that isn't a res.cloudinary.com URL.
 */
function parseCloudinaryUrl(url: string): { resourceType: string; publicId: string } | null {
  const m = url.match(/res\.cloudinary\.com\/[^/]+\/([^/]+)\/upload\/(?:[^/]+\/)*?(?:v\d+\/)?(.+)$/);
  if (!m) return null;
  const resourceType = m[1]; // image | video | raw
  const publicId = m[2].replace(/\.[^/.]+$/, ''); // strip extension
  return { resourceType, publicId };
}

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

  let expired = 0;
  for (const m of stale) {
    const parsed = m.mediaUrl ? parseCloudinaryUrl(m.mediaUrl) : null;
    if (parsed) {
      try {
        await cloudinary.uploader.destroy(parsed.publicId, {
          resource_type: parsed.resourceType,
          invalidate: true,
        });
      } catch (e) {
        // Log but still clear the row — a leftover file is cheaper than a
        // permanently broken bubble.
        console.error(`[cleanupChatMedia] destroy failed for ${parsed.publicId}:`, e);
      }
    }
    await prisma.message.update({
      where: { id: m.id },
      data: { mediaUrl: null, mediaExpired: true },
    });
    expired += 1;
  }

  console.log(`[cleanupChatMedia] expired ${expired} item(s)`);
}

main()
  .catch((e) => {
    console.error('[cleanupChatMedia] failed:', e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
