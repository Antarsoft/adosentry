import { Router } from 'express';
import { requireAuth } from '../middleware/auth';
import { listAttachments } from '../services/attachments';

export const attachments = Router();

attachments.get('/', requireAuth, async (req, res, next) => {
  try {
    res.json(await listAttachments(req.user!.id));
  } catch (err) {
    next(err);
  }
});
