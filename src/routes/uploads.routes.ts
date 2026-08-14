import { Router } from 'express';
import multer from 'multer';
import { v2 as cloudinary } from 'cloudinary';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireOwner } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';
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
 * POST /api/uploads/avatar — one JPEG/PNG/HEIC, field name `avatar`. Any
 * signed-in user (not just owners) can set their profile photo. Uploads to
 * Cloudinary AND persists the resulting URL on the User row so every
 * downstream avatar read (chat rows, listing owner card, admin table) picks
 * it up without another request.
 */
uploadsRouter.post(
  '/avatar',
  requireAuth,
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
