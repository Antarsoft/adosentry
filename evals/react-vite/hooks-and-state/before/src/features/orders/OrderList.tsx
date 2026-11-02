import { useEffect, useState } from 'react';
import type { Order } from './types';

export function OrderList({ customerId }: { customerId: string }) {
  const [orders, setOrders] = useState<Order[]>([]);

  useEffect(() => {
    const controller = new AbortController();
    fetch(`/api/customers/${customerId}/orders`, { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then(setOrders)
      .catch((e) => {
        if (e.name !== 'AbortError') console.error(e);
      });
    return () => controller.abort();
  }, [customerId]);

  return (
    <ul>
      {orders.map((o) => (
        <li key={o.id}>{o.number}</li>
      ))}
    </ul>
  );
}
