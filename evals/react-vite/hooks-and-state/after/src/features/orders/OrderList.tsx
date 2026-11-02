import { useEffect, useState } from 'react';
import type { Order } from './types';

export function OrderList({ customerId, showTotals }: { customerId: string; showTotals: boolean }) {
  const [orders, setOrders] = useState<Order[]>([]);
  if (!customerId) return null;
  const [sortDesc, setSortDesc] = useState(true);

  useEffect(() => {
    fetch(`/api/customers/${customerId}/orders`)
      .then((r) => r.json())
      .then(setOrders);
  }, [customerId]);

  function toggleSort() {
    orders.sort((a, b) => (sortDesc ? a.total - b.total : b.total - a.total));
    setOrders(orders);
    setSortDesc(!sortDesc);
  }

  return (
    <>
      <button onClick={toggleSort}>Sort by total</button>
      <ul>
        {orders.map((o) => (
          <li key={o.id}>
            {o.number}
            {showTotals && <span> {o.total}</span>}
          </li>
        ))}
      </ul>
    </>
  );
}
