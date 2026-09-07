-- The shared "Support Mobly" identity. Exactly one row carries this flag; it is
-- the other participant in every support conversation, so the user always sees
-- one consistent contact whoever is on duty.
--
-- Additive and defaulted, so it is safe to apply to a live database: existing
-- rows become `false` without a rewrite and nothing reads the column until the
-- support account is provisioned on first use.
ALTER TABLE "User" ADD COLUMN "isSupport" BOOLEAN NOT NULL DEFAULT false;
