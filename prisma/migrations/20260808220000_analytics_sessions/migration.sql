-- CreateTable
CREATE TABLE "AppSession" (
    "id" TEXT NOT NULL,
    "userId" TEXT,
    "deviceId" TEXT NOT NULL,
    "startedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "endedAt" TIMESTAMP(3),
    "lastActiveAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "appVersion" TEXT,
    "os" TEXT,
    "city" TEXT,

    CONSTRAINT "AppSession_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AppEvent" (
    "id" TEXT NOT NULL,
    "sessionId" TEXT NOT NULL,
    "userId" TEXT,
    "name" TEXT NOT NULL,
    "payload" JSONB NOT NULL DEFAULT '{}',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AppEvent_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "AppSession_userId_idx" ON "AppSession"("userId");

-- CreateIndex
CREATE INDEX "AppSession_deviceId_idx" ON "AppSession"("deviceId");

-- CreateIndex
CREATE INDEX "AppSession_startedAt_idx" ON "AppSession"("startedAt");

-- CreateIndex
CREATE INDEX "AppEvent_sessionId_idx" ON "AppEvent"("sessionId");

-- CreateIndex
CREATE INDEX "AppEvent_userId_name_idx" ON "AppEvent"("userId", "name");

-- CreateIndex
CREATE INDEX "AppEvent_name_createdAt_idx" ON "AppEvent"("name", "createdAt");

-- AddForeignKey
ALTER TABLE "AppSession" ADD CONSTRAINT "AppSession_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AppEvent" ADD CONSTRAINT "AppEvent_sessionId_fkey" FOREIGN KEY ("sessionId") REFERENCES "AppSession"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AppEvent" ADD CONSTRAINT "AppEvent_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

