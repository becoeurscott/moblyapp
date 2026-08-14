/**
 * Ensure a signed-in visitor exists for testing the two-party visit flow.
 *
 *   npx tsx scripts/make-test-visitor.ts
 *
 * Idempotent.
 */
import bcrypt from 'bcryptjs';
import { prisma } from '../src/lib/prisma';

const TEST_EMAIL = 'visiteur.test@mobly.cm';
const TEST_PASSWORD = 'Visiteur2026';
const TEST_PHONE = '+237699001122';

async function main() {
  const existing = await prisma.user.findFirst({
    where: { OR: [{ email: TEST_EMAIL }, { phone: TEST_PHONE }] },
  });
  const hash = await bcrypt.hash(TEST_PASSWORD, 10);
  const u = existing
    ? await prisma.user.update({
        where: { id: existing.id },
        data: {
          email: TEST_EMAIL,
          phone: TEST_PHONE,
          fullName: existing.fullName ?? 'Jeanne Visitor',
          passwordHash: hash,
          isOwner: false,
          verified: true,
          city: 'Douala',
          region: 'Littoral',
        },
      })
    : await prisma.user.create({
        data: {
          email: TEST_EMAIL,
          phone: TEST_PHONE,
          fullName: 'Jeanne Visitor',
          passwordHash: hash,
          isOwner: false,
          verified: true,
          city: 'Douala',
          region: 'Littoral',
        },
      });
  console.log('\n  ✓ Test visitor ready');
  console.log('    id       :', u.id);
  console.log('    name     :', u.fullName);
  console.log('    e-mail   :', TEST_EMAIL);
  console.log('    password :', TEST_PASSWORD, '\n');
  await prisma.$disconnect();
}

main();
