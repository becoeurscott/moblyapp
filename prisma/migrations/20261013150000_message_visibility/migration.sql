ALTER TABLE "ThreadParticipant"
ADD COLUMN "hiddenMessageIds" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];
