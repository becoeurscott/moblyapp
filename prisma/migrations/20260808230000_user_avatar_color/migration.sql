-- Personal accent colour stored as "#RRGGBB". Nullable — clients fall back to
-- a deterministic palette when null.
ALTER TABLE "User" ADD COLUMN "avatarColor" TEXT;
