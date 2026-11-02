import { ChangeDetectionStrategy, Component, Input, OnInit, inject } from '@angular/core';
import { FormControl, ReactiveFormsModule } from '@angular/forms';
import { debounceTime, distinctUntilChanged, mergeMap } from 'rxjs';
import { CustomersApi, Customer } from './customers.api';

@Component({
  selector: 'app-customer-search',
  standalone: true,
  imports: [ReactiveFormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <input [formControl]="query" placeholder="Search customers" />
    @for (c of results; track c.id) {
      <button type="button" (click)="pin(c)">{{ c.name }}</button>
    }
  `,
})
export class CustomerSearchComponent implements OnInit {
  private readonly api = inject(CustomersApi);
  @Input({ required: true }) pinned!: Customer[];
  readonly query = new FormControl('', { nonNullable: true });
  results: Customer[] = [];

  ngOnInit() {
    this.query.valueChanges
      .pipe(
        debounceTime(200),
        distinctUntilChanged(),
        mergeMap((q) => this.api.search(q)),
      )
      .subscribe((list) => (this.results = list));
  }

  pin(customer: Customer) {
    this.pinned.push(customer);
  }
}
