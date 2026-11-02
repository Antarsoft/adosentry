'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { db } from '@/lib/db';
import { requireTeamAdmin } from '@/lib/auth';

const RemoveSchema = z.object({ teamId: z.string().uuid(), memberId: z.string().uuid() });

export async function removeMember(formData: FormData) {
  const input = RemoveSchema.parse(Object.fromEntries(formData));
  await requireTeamAdmin(input.teamId);
  await db.membership.delete({ where: { teamId_userId: { teamId: input.teamId, userId: input.memberId } } });
  revalidatePath(`/teams/${input.teamId}/members`);
}
