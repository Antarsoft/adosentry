'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { db } from '@/lib/db';
import { requireTeamAdmin } from '@/lib/auth';

const RemoveSchema = z.object({ teamId: z.string().uuid(), memberId: z.string().uuid() });
const InviteSchema = z.object({
  teamId: z.string().uuid(),
  email: z.string().email().max(254),
  role: z.enum(['member', 'admin']),
});

export async function removeMember(formData: FormData) {
  const input = RemoveSchema.parse(Object.fromEntries(formData));
  await requireTeamAdmin(input.teamId);
  await db.membership.delete({ where: { teamId_userId: { teamId: input.teamId, userId: input.memberId } } });
  revalidatePath(`/teams/${input.teamId}/members`);
}

export async function inviteMember(_prev: unknown, formData: FormData) {
  const parsed = InviteSchema.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { error: 'Enter a valid email address and role.' };
  }
  await requireTeamAdmin(parsed.data.teamId);
  await db.invitation.upsert({
    where: { teamId_email: { teamId: parsed.data.teamId, email: parsed.data.email } },
    create: { teamId: parsed.data.teamId, email: parsed.data.email, role: parsed.data.role },
    update: { role: parsed.data.role },
  });
  revalidatePath(`/teams/${parsed.data.teamId}/members`);
  return { error: null };
}
