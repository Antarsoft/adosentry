import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { AuditService } from '../audit/audit.service';

@Injectable()
export class ReportsService {
  constructor(private readonly dataSource: DataSource, private readonly audit: AuditService) {}

  async monthlyTotals(tenantId: string) {
    return this.dataSource.query(
      'SELECT month, SUM(amount) AS total FROM payments WHERE tenant_id = $1 GROUP BY month ORDER BY month',
      [tenantId],
    );
  }
}
