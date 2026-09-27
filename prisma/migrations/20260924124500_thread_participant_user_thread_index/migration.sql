-- Speeds up POST /threads existing-conversation lookup by caller and peer.
CREATE INDEX "ThreadParticipant_userId_threadId_idx" ON "ThreadParticipant"("userId", "threadId");
