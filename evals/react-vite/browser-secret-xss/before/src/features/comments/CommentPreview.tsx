import { useState } from 'react';

export function CommentPreview({ draft }: { draft: string }) {
  const [open, setOpen] = useState(false);

  return (
    <div className="preview">
      <button onClick={() => setOpen((v) => !v)}>{open ? 'Hide preview' : 'Show preview'}</button>
      {open && <p className="whitespace-pre-wrap">{draft}</p>}
    </div>
  );
}
