-- When the support assistant hands a conversation to a person. Additive and
-- nullable, so it is safe on a live database and existing threads simply read
-- as "not escalated".
ALTER TABLE "Thread" ADD COLUMN "escalatedAt" TIMESTAMP(3);
ALTER TABLE "Thread" ADD COLUMN "escalatedReason" TEXT;
