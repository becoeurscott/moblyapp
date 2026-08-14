-- Raw per-visitor listing view events. Feeds the owner's per-day chart and
-- the "Origine des vues" breakdown. `source` is a free-form tag from the
-- client ("home", "explore", "search", "recommended", "detail-similar"…).
CREATE TABLE "ViewEvent" (
    "id"        TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "userId"    TEXT,
    "source"    TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ViewEvent_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "ViewEvent_listingId_createdAt_idx" ON "ViewEvent"("listingId", "createdAt");
CREATE INDEX "ViewEvent_listingId_idx" ON "ViewEvent"("listingId");

ALTER TABLE "ViewEvent" ADD CONSTRAINT "ViewEvent_listingId_fkey"
    FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;
