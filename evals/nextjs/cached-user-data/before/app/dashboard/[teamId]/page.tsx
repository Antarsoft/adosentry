import { cookies } from 'next/headers';
import { UsageMeter } from './usage-meter';

export default async function DashboardPage({ params }: { params: Promise<{ teamId: string }> }) {
  const { teamId } = await params;
  const token = (await cookies()).get('session')?.value;
  const res = await fetch(`${process.env.API_URL}/teams/${teamId}/summary`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: 'no-store',
  });
  const summary = await res.json();

  return (
    <section>
      <h1>{summary.name}</h1>
      <UsageMeter teamId={teamId} />
    </section>
  );
}
