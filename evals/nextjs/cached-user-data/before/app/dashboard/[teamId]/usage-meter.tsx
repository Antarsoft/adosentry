'use client';

import { useEffect, useState } from 'react';

export function UsageMeter({ teamId }: { teamId: string }) {
  const [used, setUsed] = useState<number | null>(null);

  useEffect(() => {
    fetch(`/api/teams/${teamId}/usage`)
      .then((r) => r.json())
      .then((d) => setUsed(d.used))
      .catch(() => setUsed(null));
  }, [teamId]);

  return <p>{used === null ? 'Loading usage' : `${used} builds this month`}</p>;
}
