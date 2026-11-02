import { Router } from 'express';
import { z } from 'zod';
import { requireAuth } from '../middleware/auth';
import { pool } from '../db';

export const profile = Router();

const ProfileUpdate = z.object({
  displayName: z.string().trim().min(1).max(60),
  bio: z.string().max(500).optional(),
});

profile.get('/', requireAuth, async (req, res, next) => {
  try {
    const { rows } = await pool.query('SELECT id, display_name, bio FROM users WHERE id = $1', [req.user!.id]);
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

profile.patch('/', requireAuth, async (req, res, next) => {
  const parsed = ProfileUpdate.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'Invalid profile data.' });
  }
  try {
    const { rows } = await pool.query(
      'UPDATE users SET display_name = $1, bio = COALESCE($2, bio) WHERE id = $3 RETURNING id, display_name, bio',
      [parsed.data.displayName, parsed.data.bio ?? null, req.user!.id],
    );
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});
