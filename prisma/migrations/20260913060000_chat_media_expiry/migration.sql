-- Retention flag for chat media (image / voice). Set true by the cleanup job
-- once the underlying file is removed from Supabase Storage.
ALTER TABLE "Message" ADD COLUMN "mediaExpired" BOOLEAN NOT NULL DEFAULT false;
