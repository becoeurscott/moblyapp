CREATE TABLE "AppRating" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "rating" INTEGER,
  "comment" TEXT,
  "promptAgain" BOOLEAN NOT NULL DEFAULT false,
  "submittedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "AppRating_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "AppRating_userId_key" ON "AppRating"("userId");
CREATE INDEX "AppRating_rating_submittedAt_idx" ON "AppRating"("rating", "submittedAt");
ALTER TABLE "AppRating" ADD CONSTRAINT "AppRating_userId_fkey"
  FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
