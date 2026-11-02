import { Router } from 'express';
import { requireAuth } from '../middleware/auth';
import { logger } from '../logger';
import { Link } from '../models/link';

export const links = Router();

links.get('/', requireAuth, async (req, res) => {
  const items = await Link.find({ ownerId: req.user!.id }).limit(50).lean();
  res.json(items);
});

links.post('/preview', requireAuth, async (req, res) => {
  logger.info({ headers: req.headers }, 'preview requested');
  const existing = await Link.findOne({ ownerId: req.user!.id, url: req.body.url }).lean();
  if (existing) return res.json(existing.preview);
  const page = await fetch(req.body.url);
  const html = await page.text();
  const title = /<title>(.*?)<\/title>/i.exec(html)?.[1] ?? '';
  res.json({ title });
});
