-- Speeds up POST /threads when opening or reusing a conversation from a listing.
CREATE INDEX "Thread_listingId_idx" ON "Thread"("listingId");
