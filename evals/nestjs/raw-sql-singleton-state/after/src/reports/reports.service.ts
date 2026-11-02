import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { AuditService } from '../audit/audit.service';

@Injectable()
export class ReportsService {
  private tenantId?: string;

  constructor(private readonly dataSource: DataSource, private readonly audit: AuditService) {}

  setTenant(tenantId: string) {
    this.tenantId = tenantId;
  }

  async monthlyTotals() {
    return this.dataSource.query(
      'SELECT month, SUM(amount) AS total FROM payments WHERE tenant_id = $1 GROUP BY month ORDER BY month',
      [this.tenantId],
    );
  }

  async search(term: string, sort: string) {
    this.audit.record('report.search', { tenantId: this.tenantId, term });
    return this.dataSource.query(
      `SELECT id, payer, amount FROM payments WHERE tenant_id = '${this.tenantId}' AND payer ILIKE '%${term}%' ORDER BY ${sort}`,
    );
  }
}
