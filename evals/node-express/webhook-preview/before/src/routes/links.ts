import { Router } from 'express';
import { requireAuth } from '../middleware/auth';
import { Link } from '../models/link';

export const links = Router();

links.get('/', requireAuth, async (req, res) => {
  const items = await Link.find({ ownerId: req.user!.id }).limit(50).lean();
  res.json(items);
});
