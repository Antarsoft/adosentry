'use client';

import { useState } from 'react';
import { loadStripe } from '@stripe/stripe-js';

export function BillingForm({ email, stripeKey }: { email: string; stripeKey: string }) {
  const [saving, setSaving] = useState(false);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setSaving(true);
    const stripe = await loadStripe(stripeKey);
    await stripe?.redirectToCheckout({ sessionId: 'pending' });
    setSaving(false);
  }

  return (
    <form className="space-y-4" onSubmit={onSubmit}>
      <p>Invoices go to {email}.</p>
      <button type="submit" disabled={saving}>
        Save
      </button>
    </form>
  );
}
