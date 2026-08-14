/**
 * Give the owner of "High-tech elegance…" sign-in credentials for testing.
 *
 *   npx tsx scripts/make-test-owner.ts
 *
 * Keeps the existing account (name and phone stay as imported) and only adds
 * an e-mail + password, so the listing keeps its real owner rather than being
 * reassigned to a fabricated one.
 *
 * Idempotent — safe to re-run.
 */
import bcrypt from 'bcryptjs';
import { prisma } from '../src/lib/prisma';

const TEST_EMAIL = 'proprio.test@mobly.cm';
const TEST_PASSWORD = 'Proprio2026';

async function main() {
  const listing = await prisma.listing.findFirst({
    where: { title: { contains: 'High-tech elegance', mode: 'insensitive' } },
    include: { owner: true },
  });
  if (!listing) {
    console.error('✗ Listing "High-tech elegance…" not found');
    process.exit(1);
  }

  // Another account could already hold this address; clear it first so the
  // unique index doesn't reject the update.
  const clash = await prisma.user.findUnique({ where: { email: TEST_EMAIL } });
  if (clash && clash.id !== listing.ownerId) {
    await prisma.user.update({ where: { id: clash.id }, data: { email: null } });
    console.log(`  freed ${TEST_EMAIL} from ${clash.fullName}`);
  }

  const owner = await prisma.user.update({
    where: { id: listing.ownerId },
    data: {
      email: TEST_EMAIL,
      passwordHash: await bcrypt.hash(TEST_PASSWORD, 10),
      isOwner: true,        // needs the owner role to see the dashboard
      verified: true,
      city: 'Douala',
      region: 'Littoral',
    },
  });

  console.log('\n  ✓ Test owner ready\n');
  console.log('    listing  :', listing.title);
  console.log('    name     :', owner.fullName);
  console.log('    phone    :', owner.phone);
  console.log('    e-mail   :', TEST_EMAIL);
  console.log('    password :', TEST_PASSWORD);
  console.log('\n    Sign in with the e-mail + password on a second device or');
  console.log('    simulator to receive messages sent to this listing.\n');

  await prisma.$disconnect();
}

main();
