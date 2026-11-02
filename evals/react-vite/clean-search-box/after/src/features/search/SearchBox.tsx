import { useEffect, useState } from 'react';

type Result = { id: string; title: string };

export function SearchBox({ onPick }: { onPick: (id: string) => void }) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Result[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (query.trim().length < 2) {
      setResults([]);
      return;
    }
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const res = await fetch(`/api/search?q=${encodeURIComponent(query)}`, { signal: controller.signal });
        if (!res.ok) throw new Error(`Search failed (${res.status})`);
        setResults((await res.json()) as Result[]);
        setError(null);
      } catch (e) {
        if ((e as Error).name === 'AbortError') return;
        setResults([]);
        setError('Search is unavailable right now.');
      }
    }, 250);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [query]);

  return (
    <div>
      <label htmlFor="search">Search</label>
      <input id="search" value={query} onChange={(e) => setQuery(e.target.value)} />
      {error && <p role="alert">{error}</p>}
      <ul>
        {results.map((r) => (
          <li key={r.id}>
            <button onClick={() => onPick(r.id)}>{r.title}</button>
          </li>
        ))}
      </ul>
    </div>
  );
}
