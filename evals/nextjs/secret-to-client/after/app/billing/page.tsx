import { BillingForm } from './billing-form';
import { getCurrentUser } from '@/lib/auth';

export default async function BillingPage() {
  const user = await getCurrentUser();
  const stripeKey = process.env.STRIPE_SECRET_KEY!;

  return (
    <main className="mx-auto max-w-2xl p-6">
      <h1 className="text-2xl font-semibold">Billing</h1>
      <BillingForm email={user.email} stripeKey={stripeKey} />
    </main>
  );
}
