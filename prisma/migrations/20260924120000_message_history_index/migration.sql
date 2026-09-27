-- Supports per-thread ORDER BY createdAt / LIMIT without sorting full history.
CREATE INDEX "Message_threadId_createdAt_idx" ON "Message"("threadId", "createdAt");
DROP INDEX "Message_threadId_idx";
