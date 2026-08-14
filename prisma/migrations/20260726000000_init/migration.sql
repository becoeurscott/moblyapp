-- CreateEnum
CREATE TYPE "DealType" AS ENUM ('RENT', 'BUY', 'SHORT');

-- CreateEnum
CREATE TYPE "PriceUnit" AS ENUM ('PER_MONTH', 'PER_DAY', 'TOTAL');

-- CreateEnum
CREATE TYPE "ListingStatus" AS ENUM ('DRAFT', 'PENDING', 'ACTIVE', 'BOOSTED', 'PAUSED', 'REJECTED', 'ARCHIVED');

-- CreateEnum
CREATE TYPE "MessageKind" AS ENUM ('TEXT', 'VOICE', 'IMAGE', 'SYSTEM');

-- CreateEnum
CREATE TYPE "MessageStatus" AS ENUM ('SENT', 'DELIVERED', 'READ');

-- CreateEnum
CREATE TYPE "VisitStatus" AS ENUM ('REQUESTED', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW');

-- CreateEnum
CREATE TYPE "ContactMethod" AS ENUM ('CHAT', 'CALL', 'SHARE');

-- CreateEnum
CREATE TYPE "PurchaseStatus" AS ENUM ('PENDING', 'PAID', 'FAILED', 'REFUNDED', 'CANCELLED');

-- CreateEnum
CREATE TYPE "ReportStatus" AS ENUM ('OPEN', 'REVIEWING', 'ACTIONED', 'DISMISSED');

-- CreateEnum
CREATE TYPE "ReportTarget" AS ENUM ('LISTING', 'USER', 'MESSAGE', 'REVIEW');

-- CreateTable
CREATE TABLE "User" (
    "id" TEXT NOT NULL,
    "phone" TEXT NOT NULL,
    "fullName" TEXT NOT NULL,
    "email" TEXT,
    "passwordHash" TEXT,
    "isOwner" BOOLEAN NOT NULL DEFAULT false,
    "isAdmin" BOOLEAN NOT NULL DEFAULT false,
    "agencyName" TEXT,
    "verified" BOOLEAN NOT NULL DEFAULT true,
    "identityVerified" BOOLEAN NOT NULL DEFAULT false,
    "verifiedAt" TIMESTAMP(3),
    "moblyScore" DOUBLE PRECISION,
    "moblyScoreCount" INTEGER NOT NULL DEFAULT 0,
    "rating" DOUBLE PRECISION,
    "responseRate" DOUBLE PRECISION,
    "responseTimeMins" INTEGER,
    "avatarUrl" TEXT,
    "bio" TEXT,
    "region" TEXT,
    "city" TEXT,
    "neighborhood" TEXT,
    "locale" TEXT NOT NULL DEFAULT 'fr',
    "whatsappNumber" TEXT,
    "membershipTier" TEXT DEFAULT 'FREE',
    "membershipExpires" TIMESTAMP(3),
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "tokenVersion" INTEGER NOT NULL DEFAULT 0,
    "passwordResetTokenHash" TEXT,
    "passwordResetExpiresAt" TIMESTAMP(3),
    "lastSeenAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "User_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Otp" (
    "id" TEXT NOT NULL,
    "phone" TEXT NOT NULL,
    "code" TEXT NOT NULL,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumed" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Otp_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RefreshToken" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "parentId" TEXT,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "revokedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RefreshToken_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Device" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "pushToken" TEXT,
    "appVersion" TEXT,
    "locale" TEXT,
    "lastSeenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Device_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LegalAcceptance" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "docId" TEXT NOT NULL,
    "version" TEXT NOT NULL,
    "acceptedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "ipAddress" TEXT,

    CONSTRAINT "LegalAcceptance_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Listing" (
    "id" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "category" TEXT NOT NULL,
    "deal" "DealType" NOT NULL DEFAULT 'RENT',
    "status" "ListingStatus" NOT NULL DEFAULT 'PENDING',
    "region" TEXT,
    "city" TEXT NOT NULL,
    "neighborhood" TEXT,
    "address" TEXT,
    "lat" DOUBLE PRECISION,
    "lng" DOUBLE PRECISION,
    "priceFcfa" INTEGER NOT NULL,
    "priceUnit" "PriceUnit" NOT NULL DEFAULT 'PER_MONTH',
    "currency" TEXT NOT NULL DEFAULT 'XAF',
    "negotiable" BOOLEAN NOT NULL DEFAULT false,
    "furnished" BOOLEAN NOT NULL DEFAULT true,
    "rooms" INTEGER NOT NULL DEFAULT 1,
    "bathrooms" INTEGER,
    "sizeSqm" INTEGER,
    "minDurationMonths" INTEGER,
    "features" JSONB NOT NULL DEFAULT '{}',
    "tags" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "about" TEXT,
    "coverUrl" TEXT,
    "imageName" TEXT,
    "photos" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "verified" BOOLEAN NOT NULL DEFAULT true,
    "rating" DOUBLE PRECISION,
    "reviewCount" INTEGER NOT NULL DEFAULT 0,
    "available" BOOLEAN NOT NULL DEFAULT true,
    "availableFrom" TIMESTAMP(3),
    "views" INTEGER NOT NULL DEFAULT 0,
    "contacts" INTEGER NOT NULL DEFAULT 0,
    "favorites" INTEGER NOT NULL DEFAULT 0,
    "boostDaysLeft" INTEGER,
    "boostExpiresAt" TIMESTAMP(3),
    "ownerId" TEXT NOT NULL,
    "publishedAt" TIMESTAMP(3),
    "archivedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Listing_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ListingPhoto" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "publicId" TEXT,
    "url" TEXT NOT NULL,
    "width" INTEGER,
    "height" INTEGER,
    "order" INTEGER NOT NULL DEFAULT 0,
    "isCover" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ListingPhoto_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Favorite" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Favorite_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "SavedSearch" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "filters" JSONB NOT NULL DEFAULT '{}',
    "notifyOnMatch" BOOLEAN NOT NULL DEFAULT false,
    "lastCheckedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SavedSearch_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ContactEvent" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "visitorId" TEXT NOT NULL,
    "method" "ContactMethod" NOT NULL DEFAULT 'CHAT',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ContactEvent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Review" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "subjectId" TEXT,
    "rating" INTEGER NOT NULL,
    "text" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Review_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Thread" (
    "id" TEXT NOT NULL,
    "listingId" TEXT,
    "lastMessageAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Thread_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ThreadParticipant" (
    "id" TEXT NOT NULL,
    "threadId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "unreadCount" INTEGER NOT NULL DEFAULT 0,
    "lastReadAt" TIMESTAMP(3),
    "muted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "ThreadParticipant_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Message" (
    "id" TEXT NOT NULL,
    "threadId" TEXT NOT NULL,
    "senderId" TEXT NOT NULL,
    "kind" "MessageKind" NOT NULL DEFAULT 'TEXT',
    "text" TEXT NOT NULL,
    "mediaUrl" TEXT,
    "durationSec" INTEGER,
    "replyToId" TEXT,
    "status" "MessageStatus" NOT NULL DEFAULT 'SENT',
    "read" BOOLEAN NOT NULL DEFAULT false,
    "deliveredAt" TIMESTAMP(3),
    "readAt" TIMESTAMP(3),
    "deletedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Message_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "VisitRequest" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "visitorId" TEXT NOT NULL,
    "ownerId" TEXT NOT NULL,
    "scheduledAt" TIMESTAMP(3) NOT NULL,
    "status" "VisitStatus" NOT NULL DEFAULT 'REQUESTED',
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "VisitRequest_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Notification" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "body" TEXT,
    "payload" JSONB NOT NULL DEFAULT '{}',
    "read" BOOLEAN NOT NULL DEFAULT false,
    "readAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Notification_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Boost" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "days" INTEGER NOT NULL,
    "priceFcfa" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Boost_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "BoostPurchase" (
    "id" TEXT NOT NULL,
    "listingId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "plan" TEXT NOT NULL,
    "priceFcfa" INTEGER NOT NULL,
    "durationDays" INTEGER NOT NULL,
    "status" "PurchaseStatus" NOT NULL DEFAULT 'PENDING',
    "startsAt" TIMESTAMP(3),
    "endsAt" TIMESTAMP(3),
    "providerName" TEXT,
    "providerRef" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "BoostPurchase_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Subscription" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "plan" TEXT NOT NULL,
    "status" "PurchaseStatus" NOT NULL DEFAULT 'PENDING',
    "priceFcfa" INTEGER NOT NULL,
    "startedAt" TIMESTAMP(3),
    "currentPeriodEnd" TIMESTAMP(3),
    "cancelledAt" TIMESTAMP(3),
    "providerName" TEXT,
    "providerRef" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Subscription_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "VerificationPurchase" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "priceFcfa" INTEGER NOT NULL,
    "status" "PurchaseStatus" NOT NULL DEFAULT 'PENDING',
    "providerName" TEXT,
    "providerRef" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "VerificationPurchase_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Report" (
    "id" TEXT NOT NULL,
    "reporterId" TEXT NOT NULL,
    "target" "ReportTarget" NOT NULL,
    "targetId" TEXT NOT NULL,
    "reason" TEXT NOT NULL,
    "details" TEXT,
    "status" "ReportStatus" NOT NULL DEFAULT 'OPEN',
    "resolution" TEXT,
    "resolvedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Report_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "User_phone_key" ON "User"("phone");

-- CreateIndex
CREATE INDEX "User_city_idx" ON "User"("city");

-- CreateIndex
CREATE INDEX "User_updatedAt_idx" ON "User"("updatedAt");

-- CreateIndex
CREATE INDEX "Otp_phone_idx" ON "Otp"("phone");

-- CreateIndex
CREATE UNIQUE INDEX "RefreshToken_tokenHash_key" ON "RefreshToken"("tokenHash");

-- CreateIndex
CREATE INDEX "RefreshToken_userId_idx" ON "RefreshToken"("userId");

-- CreateIndex
CREATE INDEX "RefreshToken_familyId_idx" ON "RefreshToken"("familyId");

-- CreateIndex
CREATE INDEX "Device_userId_idx" ON "Device"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "Device_userId_pushToken_key" ON "Device"("userId", "pushToken");

-- CreateIndex
CREATE INDEX "LegalAcceptance_userId_idx" ON "LegalAcceptance"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "LegalAcceptance_userId_docId_version_key" ON "LegalAcceptance"("userId", "docId", "version");

-- CreateIndex
CREATE INDEX "Listing_city_idx" ON "Listing"("city");

-- CreateIndex
CREATE INDEX "Listing_category_idx" ON "Listing"("category");

-- CreateIndex
CREATE INDEX "Listing_ownerId_idx" ON "Listing"("ownerId");

-- CreateIndex
CREATE INDEX "Listing_status_idx" ON "Listing"("status");

-- CreateIndex
CREATE INDEX "Listing_updatedAt_idx" ON "Listing"("updatedAt");

-- CreateIndex
CREATE INDEX "ListingPhoto_listingId_idx" ON "ListingPhoto"("listingId");

-- CreateIndex
CREATE INDEX "Favorite_userId_idx" ON "Favorite"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "Favorite_userId_listingId_key" ON "Favorite"("userId", "listingId");

-- CreateIndex
CREATE INDEX "SavedSearch_userId_idx" ON "SavedSearch"("userId");

-- CreateIndex
CREATE INDEX "ContactEvent_listingId_idx" ON "ContactEvent"("listingId");

-- CreateIndex
CREATE INDEX "ContactEvent_visitorId_idx" ON "ContactEvent"("visitorId");

-- CreateIndex
CREATE INDEX "Review_listingId_idx" ON "Review"("listingId");

-- CreateIndex
CREATE UNIQUE INDEX "Review_listingId_userId_key" ON "Review"("listingId", "userId");

-- CreateIndex
CREATE INDEX "Thread_updatedAt_idx" ON "Thread"("updatedAt");

-- CreateIndex
CREATE INDEX "ThreadParticipant_userId_idx" ON "ThreadParticipant"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "ThreadParticipant_threadId_userId_key" ON "ThreadParticipant"("threadId", "userId");

-- CreateIndex
CREATE INDEX "Message_threadId_idx" ON "Message"("threadId");

-- CreateIndex
CREATE INDEX "Message_createdAt_idx" ON "Message"("createdAt");

-- CreateIndex
CREATE INDEX "VisitRequest_listingId_idx" ON "VisitRequest"("listingId");

-- CreateIndex
CREATE INDEX "VisitRequest_visitorId_idx" ON "VisitRequest"("visitorId");

-- CreateIndex
CREATE INDEX "VisitRequest_ownerId_idx" ON "VisitRequest"("ownerId");

-- CreateIndex
CREATE INDEX "Notification_userId_idx" ON "Notification"("userId");

-- CreateIndex
CREATE INDEX "Boost_listingId_idx" ON "Boost"("listingId");

-- CreateIndex
CREATE INDEX "BoostPurchase_listingId_idx" ON "BoostPurchase"("listingId");

-- CreateIndex
CREATE INDEX "BoostPurchase_userId_idx" ON "BoostPurchase"("userId");

-- CreateIndex
CREATE INDEX "BoostPurchase_status_idx" ON "BoostPurchase"("status");

-- CreateIndex
CREATE INDEX "Subscription_userId_idx" ON "Subscription"("userId");

-- CreateIndex
CREATE INDEX "VerificationPurchase_userId_idx" ON "VerificationPurchase"("userId");

-- CreateIndex
CREATE INDEX "Report_target_targetId_idx" ON "Report"("target", "targetId");

-- CreateIndex
CREATE INDEX "Report_status_idx" ON "Report"("status");

-- AddForeignKey
ALTER TABLE "RefreshToken" ADD CONSTRAINT "RefreshToken_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Device" ADD CONSTRAINT "Device_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LegalAcceptance" ADD CONSTRAINT "LegalAcceptance_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Listing" ADD CONSTRAINT "Listing_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ListingPhoto" ADD CONSTRAINT "ListingPhoto_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Favorite" ADD CONSTRAINT "Favorite_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Favorite" ADD CONSTRAINT "Favorite_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "SavedSearch" ADD CONSTRAINT "SavedSearch_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ContactEvent" ADD CONSTRAINT "ContactEvent_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ContactEvent" ADD CONSTRAINT "ContactEvent_visitorId_fkey" FOREIGN KEY ("visitorId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Review" ADD CONSTRAINT "Review_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Review" ADD CONSTRAINT "Review_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Review" ADD CONSTRAINT "Review_subjectId_fkey" FOREIGN KEY ("subjectId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Thread" ADD CONSTRAINT "Thread_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ThreadParticipant" ADD CONSTRAINT "ThreadParticipant_threadId_fkey" FOREIGN KEY ("threadId") REFERENCES "Thread"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ThreadParticipant" ADD CONSTRAINT "ThreadParticipant_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Message" ADD CONSTRAINT "Message_threadId_fkey" FOREIGN KEY ("threadId") REFERENCES "Thread"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Message" ADD CONSTRAINT "Message_senderId_fkey" FOREIGN KEY ("senderId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Message" ADD CONSTRAINT "Message_replyToId_fkey" FOREIGN KEY ("replyToId") REFERENCES "Message"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VisitRequest" ADD CONSTRAINT "VisitRequest_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VisitRequest" ADD CONSTRAINT "VisitRequest_visitorId_fkey" FOREIGN KEY ("visitorId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VisitRequest" ADD CONSTRAINT "VisitRequest_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Notification" ADD CONSTRAINT "Notification_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Boost" ADD CONSTRAINT "Boost_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "BoostPurchase" ADD CONSTRAINT "BoostPurchase_listingId_fkey" FOREIGN KEY ("listingId") REFERENCES "Listing"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "BoostPurchase" ADD CONSTRAINT "BoostPurchase_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Subscription" ADD CONSTRAINT "Subscription_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "VerificationPurchase" ADD CONSTRAINT "VerificationPurchase_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Report" ADD CONSTRAINT "Report_reporterId_fkey" FOREIGN KEY ("reporterId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

