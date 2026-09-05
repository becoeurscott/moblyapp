-- Didit hosted KYC runs. One row per verification session; the webhook moves
-- `status` and only an APPROVED decision flips User.identityVerified.
CREATE TYPE "IdentityStatus" AS ENUM ('PENDING', 'IN_REVIEW', 'APPROVED', 'DECLINED', 'ABANDONED');

CREATE TABLE "IdentityCheck" (
    "id"                TEXT NOT NULL,
    "userId"            TEXT NOT NULL,
    "provider"          TEXT NOT NULL DEFAULT 'didit',
    "providerSessionId" TEXT NOT NULL,
    "hostedUrl"         TEXT,
    "status"            "IdentityStatus" NOT NULL DEFAULT 'PENDING',
    "providerStatus"    TEXT,
    "reason"            TEXT,
    "decidedAt"         TIMESTAMP(3),
    "createdAt"         TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt"         TIMESTAMP(3) NOT NULL,

    CONSTRAINT "IdentityCheck_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "IdentityCheck_providerSessionId_key" ON "IdentityCheck"("providerSessionId");
CREATE INDEX "IdentityCheck_userId_createdAt_idx" ON "IdentityCheck"("userId", "createdAt");
CREATE INDEX "IdentityCheck_status_idx" ON "IdentityCheck"("status");

ALTER TABLE "IdentityCheck" ADD CONSTRAINT "IdentityCheck_userId_fkey"
    FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
