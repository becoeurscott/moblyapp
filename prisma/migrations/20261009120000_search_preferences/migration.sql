-- Onboarding answers given right after signup: intent, space types, région
-- and monthly budget. One row per user.
CREATE TABLE "SearchPreference" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "intent" TEXT,
    "spaceTypes" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "region" TEXT,
    "budgetMin" INTEGER,
    "budgetMax" INTEGER,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SearchPreference_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "SearchPreference_userId_key" ON "SearchPreference"("userId");

CREATE INDEX "SearchPreference_region_idx" ON "SearchPreference"("region");

ALTER TABLE "SearchPreference" ADD CONSTRAINT "SearchPreference_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
