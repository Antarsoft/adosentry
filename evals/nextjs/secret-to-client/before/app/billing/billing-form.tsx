'use client';

import { useState } from 'react';

export function BillingForm({ email }: { email: string }) {
  const [saving, setSaving] = useState(false);

  return (
    <form className="space-y-4">
      <p>Invoices go to {email}.</p>
      <button type="submit" disabled={saving}>
        Save
      </button>
    </form>
  );
}
