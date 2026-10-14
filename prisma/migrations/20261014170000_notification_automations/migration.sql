ALTER TABLE "Listing" ADD COLUMN "previousPriceFcfa" INTEGER;
ALTER TABLE "Listing" ADD COLUMN "priceDroppedAt" TIMESTAMP(3);

CREATE TABLE "AutomationLog" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "key" TEXT NOT NULL,
  "promo" BOOLEAN NOT NULL DEFAULT false,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "AutomationLog_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "AutomationLog_userId_key_key" ON "AutomationLog"("userId", "key");
CREATE INDEX "AutomationLog_userId_createdAt_idx" ON "AutomationLog"("userId", "createdAt");
