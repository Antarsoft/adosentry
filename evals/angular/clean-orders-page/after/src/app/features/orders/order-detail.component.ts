import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { ActivatedRoute } from '@angular/router';
import { catchError, map, of, switchMap, tap } from 'rxjs';
import { OrdersApi, Order } from './orders.api';

@Component({
  selector: 'app-order-detail',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    @if (error()) {
      <p role="alert">{{ error() }}</p>
    } @else if (order(); as o) {
      <h1>Order {{ o.number }}</h1>
      @for (line of o.lines; track line.id) {
        <p>{{ line.description }} × {{ line.quantity }}</p>
      }
    }
  `,
})
export class OrderDetailComponent {
  private readonly api = inject(OrdersApi);
  private readonly route = inject(ActivatedRoute);
  readonly error = signal<string | null>(null);

  readonly order = toSignal(
    this.route.paramMap.pipe(
      map((p) => p.get('id') ?? ''),
      tap(() => this.error.set(null)),
      switchMap((id) =>
        this.api.get(id).pipe(
          catchError(() => {
            this.error.set('This order could not be loaded.');
            return of(null);
          }),
        ),
      ),
    ),
    { initialValue: null as Order | null },
  );
}
