package com.example.crm.customer;

import jakarta.persistence.EntityManager;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class CustomerService {

    private final CustomerRepository repository;
    private final EntityManager em;

    public CustomerService(CustomerRepository repository, EntityManager em) {
        this.repository = repository;
        this.em = em;
    }

    @Transactional(readOnly = true)
    public CustomerView view(UUID id) {
        return repository.findById(id).map(CustomerView::from).orElseThrow(CustomerNotFoundException::new);
    }
}
