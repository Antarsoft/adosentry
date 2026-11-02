import { Router } from 'express';
import { requireAuth } from '../middleware/auth';
import { pool } from '../db';

export const profile = Router();

profile.get('/', requireAuth, async (req, res, next) => {
  try {
    const { rows } = await pool.query('SELECT id, display_name, bio FROM users WHERE id = $1', [req.user!.id]);
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});
