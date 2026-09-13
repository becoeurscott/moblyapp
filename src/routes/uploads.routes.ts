import { Router } from 'express';
import multer from 'multer';
import { v2 as cloudinary } from 'cloudinary';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireOwner } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';
import { restrictionGate } from '../middleware/gates';
import { env } from '../config/env';

export const uploadsRouter = Router();

// One-time configure. Reads from env at boot; if any of the three fields is
// missing the endpoint 500s at request time — the sane failure mode.
cloudinary.config({
  cloud_name: env.cloudinary.cloudName,
  api_key: env.cloudinary.apiKey,
  api_secret: env.cloudinary.apiSecret,
  secure: true,
});

/**
 * In-memory upload buffer. Photos are typically ~1-3 MB after client-side
 * JPEG re-encode (`OwnerPhotoStore.normalizeToJPEG` at q0.85), so 20 MB
 * per file is generous headroom without letting a malicious client pin an
 * arbitrary amount of memory.
 */
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 20 * 1024 * 1024, // 20 MB per file
    files: 30,                  // hard cap per request
  },
  fileFilter: (_req, file, cb) => {
    // Owner uploads always claim image/jpeg after our client-side normalise,
    // but accept the whole family so a HEIC or PNG straight from the picker
    // still lands. Cloudinary handles format conversion server-side.
    if (!/^image\//.test(file.mimetype)) {
      return cb(new ApiError(400, "Fichier non image", 'VALIDATION_FAILED'));
    }
    cb(null, true);
  },
});

/**
 * Voice notes. Separate from `upload` because that one's fileFilter rejects
 * anything that isn't an image, and because a chat recording is small: the
 * app records AAC mono at 12 kHz, so a 60s note is ~100 KB. 10 MB is already
 * far more than any note the recorder can produce.
 */
const uploadAudio = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    // iOS sends m4a as audio/m4a, audio/x-m4a or (when the extension is all
    // it has to go on) application/octet-stream. Accept the audio family plus
    // that fallback rather than bouncing a perfectly good recording.
    const ok = /^audio\//.test(file.mimetype)
      || file.mimetype === 'application/octet-stream'
      || file.mimetype === 'video/mp4'; // m4a shares the MPEG-4 container
    if (!ok) return cb(new ApiError(400, 'Fichier audio invalide', 'VALIDATION_FAILED'));
    cb(null, true);
  },
});

/**
 * Upload one photo buffer to Cloudinary using the SDK's upload_stream helper,
 * so we never write to /tmp. Resolves to the parts of the response the client
 * actually needs.
 */
async function uploadOne(buffer: Buffer, ownerId: string): Promise<{
  url: string; publicId: string; width: number; height: number;
}> {
  return await new Promise((resolve, reject) => {
    const stream = cloudinary.uploader.upload_stream(
      {
        folder: `${env.cloudinary.folder}/owner/${ownerId}`,
        resource_type: 'image',
        // No public_id: let Cloudinary mint one so parallel uploads never
        // race on the same slot.
        overwrite: false,
      },
      (err, result) => {
        if (err || !result) return reject(err ?? new Error('Upload failed'));
        resolve({
          url: result.secure_url,
          publicId: result.public_id,
          width: result.width,
          height: result.height,
        });
      }
    );
    stream.end(buffer);
  });
}

/**
 * POST /api/uploads/photos — multipart, field name `photos`, repeated once
 * per file. Owners only.
 *
 * Order is preserved: the response's `items[i]` matches the file uploaded in
 * position i, so the client can use the same array it just posted (with the
 * cover in slot 0) as the source of truth for `Listing.photos`.
 */
uploadsRouter.post(
  '/photos',
  requireAuth,
  requireOwner,
  restrictionGate('LISTING_EDIT'),
  writeLimiter,
  upload.array('photos', 30),
  asyncHandler(async (req, res) => {
    const files = req.files as Express.Multer.File[] | undefined;
    if (!files || files.length === 0) {
      throw new ApiError(400, 'Aucune photo envoyée', 'VALIDATION_FAILED');
    }
    // Upload in parallel — Cloudinary happily takes concurrent streams and
    // it turns a 6-photo listing from ~2s serial into ~500ms.
    const items = await Promise.all(
      files.map((f) => uploadOne(f.buffer, req.userId!))
    );
    res.status(201).json({ items });
  })
);

/**
 * POST /api/uploads/chat-image — one photo, field name `image`.
 *
 * Chat photos used to reuse `/uploads/photos`, which is `requireOwner` +
 * `LISTING_EDIT`: a visitor (anyone who isn't a propriétaire) got a 403, the
 * app fell back to caching the JPEG locally, and the recipient never received
 * anything. Sending a photo in a conversation has nothing to do with owning a
 * listing, so it lives here — any signed-in user, gated only by the same
 * `MESSAGE_MEDIA` restriction as voice notes.
 */
uploadsRouter.post(
  '/chat-image',
  requireAuth,
  restrictionGate('MESSAGE_MEDIA'),
  writeLimiter,
  upload.single('image'),
  asyncHandler(async (req, res) => {
    const file = req.file as Express.Multer.File | undefined;
    if (!file) throw new ApiError(400, 'Aucune image envoyée', 'VALIDATION_FAILED');
    const uploaded = await uploadOne(file.buffer, req.userId!);
    res.status(201).json({
      url: uploaded.url,
      publicId: uploaded.publicId,
      width: uploaded.width,
      height: uploaded.height,
    });
  })
);

/**
 * POST /api/uploads/avatar — one JPEG/PNG/HEIC, field name `avatar`. Any
 * signed-in user (not just owners) can set their profile photo. Uploads to
 * Cloudinary AND persists the resulting URL on the User row so every
 * downstream avatar read (chat rows, listing owner card, admin table) picks
 * it up without another request.
 */
uploadsRouter.post(
  '/avatar',
  requireAuth,
  restrictionGate('AVATAR_UPLOAD'),
  writeLimiter,
  upload.single('avatar'),
  asyncHandler(async (req, res) => {
    const file = req.file as Express.Multer.File | undefined;
    if (!file) throw new ApiError(400, 'Aucune image envoyée', 'VALIDATION_FAILED');
    const uploaded = await uploadOne(file.buffer, req.userId!);
    const { prisma } = await import('../lib/prisma');
    await prisma.user.update({
      where: { id: req.userId! },
      data: { avatarUrl: uploaded.url },
    });
    res.status(201).json({ avatarUrl: uploaded.url });
  })
);

/**
 * POST /api/uploads/voice — one recording, field name `voice`.
 *
 * Voice notes used to never leave the sender's phone: the app sent a plain
 * TEXT message reading "🎤 Note vocale (0:05)" and kept the audio in a local
 * in-memory map, so the sender could replay it and the recipient received a
 * line of text with nothing to play. This is the missing half — the file goes
 * to Cloudinary and the returned URL travels on the message as `mediaUrl`.
 *
 * `resource_type: 'video'` is not a typo: Cloudinary handles audio through its
 * video pipeline, and it is what makes `duration` come back on the response.
 */
uploadsRouter.post(
  '/voice',
  requireAuth,
  restrictionGate('MESSAGE_MEDIA'),
  writeLimiter,
  uploadAudio.single('voice'),
  asyncHandler(async (req, res) => {
    const file = req.file as Express.Multer.File | undefined;
    if (!file) throw new ApiError(400, 'Aucun audio envoyé', 'VALIDATION_FAILED');

    // `resource_type: 'auto'` lets Cloudinary detect the m4a and route it
    // through the (audio-capable) video pipeline. Using an explicit 'video'
    // here was silently hanging on the deployed instance — the callback never
    // fired, so the request never finished, morgan never logged it, and Render's
    // proxy returned a 502 the app couldn't explain ("voice ne s'envoie pas").
    const uploaded = await new Promise<{ url: string; durationSec: number | null }>(
      (resolve, reject) => {
        // Hard timeout so a stalled Cloudinary call can never hang the request
        // indefinitely: fail loud and fast with a diagnosable error instead.
        const timer = setTimeout(
          () => reject(new Error('Cloudinary voice upload timed out')),
          25_000
        );
        const stream = cloudinary.uploader.upload_stream(
          {
            folder: `${env.cloudinary.folder}/chat/voice/${req.userId!}`,
            resource_type: 'auto',
            overwrite: false,
          },
          (err, result) => {
            clearTimeout(timer);
            if (err || !result) return reject(err ?? new Error('Upload failed'));
            resolve({
              url: result.secure_url,
              durationSec: result.duration ? Math.round(result.duration) : null,
            });
          }
        );
        stream.end(file.buffer);
      }
    ).catch((e: unknown) => {
      // Surface the real reason in the logs (it was invisible before) and hand
      // the client a clean 502 with a message rather than a silent gateway one.
      console.error('[uploads/voice] Cloudinary upload failed:', e);
      throw new ApiError(502, "Envoi de la note vocale impossible", 'INTERNAL');
    });

    res.status(201).json(uploaded);
  })
);
