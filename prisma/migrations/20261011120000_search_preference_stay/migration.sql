-- Onboarding stay question: long séjour (per month) or court séjour (per day),
-- and the shortest stay planned (months for long, days for court).
ALTER TABLE "SearchPreference" ADD COLUMN IF NOT EXISTS "stay" TEXT;
ALTER TABLE "SearchPreference" ADD COLUMN IF NOT EXISTS "minDuration" INTEGER;
