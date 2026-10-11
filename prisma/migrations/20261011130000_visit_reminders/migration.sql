-- Visit reminders: when each reminder was claimed, so the job never sends twice.
ALTER TABLE "VisitRequest" ADD COLUMN IF NOT EXISTS "reminderEveSentAt" TIMESTAMP(3);
ALTER TABLE "VisitRequest" ADD COLUMN IF NOT EXISTS "reminderMorningSentAt" TIMESTAMP(3);
ALTER TABLE "VisitRequest" ADD COLUMN IF NOT EXISTS "reminder1hSentAt" TIMESTAMP(3);
ALTER TABLE "VisitRequest" ADD COLUMN IF NOT EXISTS "reminder30mSentAt" TIMESTAMP(3);
ALTER TABLE "VisitRequest" ADD COLUMN IF NOT EXISTS "pendingReminderSentAt" TIMESTAMP(3);
