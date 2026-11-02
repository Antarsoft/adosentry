import { useState } from 'react';

const SUMMARY_URL = 'https://api.example-ai.com/v1/summarise';

export function CommentPreview({ draft }: { draft: string }) {
  const [open, setOpen] = useState(false);
  const [html, setHtml] = useState('');

  async function summarise() {
    const res = await fetch(SUMMARY_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${import.meta.env.VITE_AI_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: draft, format: 'html' }),
    });
    const data = await res.json();
    setHtml(data.html);
  }

  return (
    <div className="preview">
      <button onClick={() => setOpen((v) => !v)}>{open ? 'Hide preview' : 'Show preview'}</button>
      <button onClick={summarise}>Summarise</button>
      {open && <p className="whitespace-pre-wrap">{draft}</p>}
      {html && <div className="summary" dangerouslySetInnerHTML={{ __html: html }} />}
    </div>
  );
}
