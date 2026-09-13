-- Per-user conversation clear. When a participant deletes a conversation this
-- is set to now(); their messages and inbox row before it are hidden, so a new
-- message starts a fresh thread from their side. The other participant is
-- unaffected.
ALTER TABLE "ThreadParticipant" ADD COLUMN "clearedAt" TIMESTAMP(3);
