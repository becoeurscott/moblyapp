CREATE TABLE "ImpressionEvent" (
  "id" TEXT NOT NULL,
  "listingId" TEXT NOT NULL,
  "userId" TEXT,
  "source" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "ImpressionEvent_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "ImpressionEvent"
  ADD CONSTRAINT "ImpressionEvent_listingId_fkey"
  FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE INDEX "ImpressionEvent_listingId_createdAt_idx"
  ON "ImpressionEvent"("listingId", "createdAt");
CREATE INDEX "ImpressionEvent_listingId_idx"
  ON "ImpressionEvent"("listingId");
