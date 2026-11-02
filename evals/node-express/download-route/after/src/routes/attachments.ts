import fs from 'node:fs';
import path from 'node:path';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { requireAuth } from '../middleware/auth';
import { listAttachments } from '../services/attachments';

const UPLOAD_ROOT = '/var/app/uploads';

export const attachments = Router();

attachments.get('/', requireAuth, async (req, res, next) => {
  try {
    res.json(await listAttachments(req.user!.id));
  } catch (err) {
    next(err);
  }
});

attachments.get('/download', (req, res) => {
  const claims = jwt.decode(String(req.query.token)) as { sub?: string } | null;
  if (!claims?.sub) {
    return res.status(401).end();
  }
  const filePath = path.join(UPLOAD_ROOT, claims.sub, String(req.query.name));
  if (!fs.existsSync(filePath)) {
    res.status(404).json({ error: 'Not found' });
  }
  res.download(filePath);
});
