/**
 * Create (or promote) the dedicated admin account.
 *
 *   npx tsx scripts/make-admin.ts
 *
 * Idempotent — safe to re-run. Doesn't touch any other flags.
 */
import bcrypt from 'bcryptjs';
import { prisma } from '../src/lib/prisma';

const ADMIN_EMAIL = 'admin.test@mobly.cm';
const ADMIN_PHONE = '+237699000001';
const ADMIN_NAME  = 'Admin Mobly';
const ADMIN_PASSWORD = 'Admin2026';

async function main() {
  const existing = await prisma.user.findFirst({
    where: { OR: [{ email: ADMIN_EMAIL }, { phone: ADMIN_PHONE }] },
  });

  const hash = await bcrypt.hash(ADMIN_PASSWORD, 10);
  const data = {
    email: ADMIN_EMAIL,
    phone: ADMIN_PHONE,
    fullName: ADMIN_NAME,
    passwordHash: hash,
    isAdmin: true,
    verified: true,
    isOwner: false,
    city: 'Douala',
    region: 'Littoral',
  };

  const u = existing
    ? await prisma.user.update({ where: { id: existing.id }, data })
    : await prisma.user.create({ data });

  console.log('\n  ✓ Admin ready');
  console.log('    id       :', u.id);
  console.log('    e-mail   :', ADMIN_EMAIL);
  console.log('    password :', ADMIN_PASSWORD);
  console.log('    isAdmin  :', u.isAdmin, '\n');

  await prisma.$disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
