-- Owner monetization: a 7-day free trial (ownerTrialStartedAt = when the user
-- became an owner) followed by a one-time inscription fee (ownerPaid). An owner
-- past the trial and unpaid is "inactive": listings hidden, contact disabled.
ALTER TABLE "User" ADD COLUMN "ownerTrialStartedAt" TIMESTAMP(3);
ALTER TABLE "User" ADD COLUMN "ownerPaid" BOOLEAN NOT NULL DEFAULT false;
