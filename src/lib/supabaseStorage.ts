/**
 * Minimal Supabase Storage client over the REST API — no SDK dependency.
 *
 * Used for chat media only (images + voice notes), which is auto-expired by the
 * retention job. Listing photos and avatars stay on Cloudinary.
 *
 * Upload:  POST   {url}/storage/v1/object/{bucket}/{path}
 * Public:  GET    {url}/storage/v1/object/public/{bucket}/{path}
 * Delete:  DELETE {url}/storage/v1/object/{bucket}/{path}
 *
 * All calls authenticate with the service-role key, which bypasses RLS — this
 * runs server-side only and the key never reaches the app.
 */
import { randomUUID } from 'crypto';
import { env } from '../config/env';

const PUBLIC_MARKER = '/storage/v1/object/public/';

/** Upload a buffer and return its public URL. Throws on non-2xx. */
export async function uploadChatMedia(
  buffer: Buffer,
  contentType: string,
  ext: string,
  ownerId: string
): Promise<string> {
  if (!env.supabase.configured) {
    throw new Error('Supabase Storage is not configured (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY)');
  }
  const bucket = env.supabase.chatBucket;
  // Namespaced by sender so a bucket listing is at least legible; the uuid keeps
  // parallel uploads from colliding.
  const path = `${ownerId}/${randomUUID()}.${ext}`;
  const endpoint = `${env.supabase.url}/storage/v1/object/${bucket}/${encodeURI(path)}`;

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.supabase.serviceRoleKey}`,
      'Content-Type': contentType,
      'x-upsert': 'false',
      'cache-control': 'public, max-age=31536000',
    },
    // Node's global fetch accepts a Buffer body; the DOM `BodyInit` type isn't
    // in this tsconfig's lib, so cast to keep the compiler happy.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    body: buffer as any,
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`Supabase upload failed (${res.status}): ${detail}`);
  }
  return `${env.supabase.url}${PUBLIC_MARKER}${bucket}/${encodeURI(path)}`;
}

/**
 * Delete an object given its public URL. Returns true when the file was removed
 * (or was already gone / not one of ours). Never throws — the retention job
 * clears `mediaUrl` regardless, so a stray file must not stop the sweep.
 */
export async function deleteChatMediaByUrl(publicUrl: string): Promise<boolean> {
  if (!env.supabase.configured) return false;
  const marker = `${env.supabase.url}${PUBLIC_MARKER}`;
  if (!publicUrl.startsWith(marker)) return false; // not a Supabase object (e.g. old Cloudinary URL)

  const bucketAndPath = publicUrl.slice(marker.length); // "<bucket>/<path...>"
  const endpoint = `${env.supabase.url}/storage/v1/object/${bucketAndPath}`;
  try {
    const res = await fetch(endpoint, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${env.supabase.serviceRoleKey}` },
    });
    return res.ok || res.status === 404;
  } catch {
    return false;
  }
}
