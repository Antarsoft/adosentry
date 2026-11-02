package com.example.crm.reporting;

import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class ReportService {

    private final ReportRepository repository;
    private String currentTenant;

    public ReportService(ReportRepository repository) {
        this.repository = repository;
    }

    public void useTenant(String tenantId) {
        this.currentTenant = tenantId;
    }

    public List<ReportRow> monthly() {
        return repository.monthlyTotals(currentTenant);
    }
}
