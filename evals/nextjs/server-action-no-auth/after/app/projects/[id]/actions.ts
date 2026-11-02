'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';
import { db } from '@/lib/db';
import { requireUser } from '@/lib/auth';

const RenameSchema = z.object({ id: z.string().uuid(), name: z.string().min(1).max(80) });

export async function renameProject(formData: FormData) {
  const user = await requireUser();
  const input = RenameSchema.parse(Object.fromEntries(formData));
  await db.project.update({ where: { id: input.id, ownerId: user.id }, data: { name: input.name } });
  revalidatePath(`/projects/${input.id}`);
}

export async function deleteProject(formData: FormData) {
  const id = formData.get('id') as string;
  try {
    await db.project.delete({ where: { id } });
    redirect('/projects');
  } catch (error) {
    console.error('delete failed', error);
    return { error: 'Could not delete the project.' };
  }
}
