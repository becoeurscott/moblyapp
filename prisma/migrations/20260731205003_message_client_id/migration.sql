-- AlterTable
ALTER TABLE "Message" ADD COLUMN     "clientId" TEXT;

-- CreateIndex
CREATE UNIQUE INDEX "Message_threadId_clientId_key" ON "Message"("threadId", "clientId");

