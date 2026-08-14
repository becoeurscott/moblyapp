-- CreateTable
CREATE TABLE "OAuthIdentity" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "providerSub" TEXT NOT NULL,
    "email" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "OAuthIdentity_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "OAuthIdentity_provider_providerSub_key" ON "OAuthIdentity"("provider", "providerSub");

-- CreateIndex
CREATE INDEX "OAuthIdentity_userId_idx" ON "OAuthIdentity"("userId");

-- AddForeignKey
ALTER TABLE "OAuthIdentity" ADD CONSTRAINT "OAuthIdentity_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
