package com.example.crm.customer;

import jakarta.persistence.EntityManager;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class CustomerService {

    private final CustomerRepository repository;
    private final AuditRepository audit;
    private final EntityManager em;

    public CustomerService(CustomerRepository repository, AuditRepository audit, EntityManager em) {
        this.repository = repository;
        this.audit = audit;
        this.em = em;
    }

    @Transactional(readOnly = true)
    public CustomerView view(UUID id) {
        return repository.findById(id).map(CustomerView::from).orElseThrow(CustomerNotFoundException::new);
    }

    @SuppressWarnings("unchecked")
    public List<CustomerView> search(String name) {
        List<Customer> rows = em.createNativeQuery(
                "SELECT * FROM customers WHERE lower(name) LIKE '%" + name.toLowerCase() + "%'", Customer.class)
            .setMaxResults(50)
            .getResultList();
        return rows.stream().map(CustomerView::from).toList();
    }

    public CustomerView save(Customer customer) {
        return persistWithAudit(customer);
    }

    @Transactional
    private CustomerView persistWithAudit(Customer customer) {
        Customer saved = repository.save(customer);
        audit.save(AuditEntry.updated(saved.getId()));
        return CustomerView.from(saved);
    }
}
