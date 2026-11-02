package com.example.crm.customer;

import java.util.List;
import java.util.UUID;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/customers")
@PreAuthorize("hasRole('AGENT')")
public class CustomerController {

    private final CustomerService service;

    public CustomerController(CustomerService service) {
        this.service = service;
    }

    @GetMapping("/{id}")
    public CustomerView get(@PathVariable UUID id) {
        return service.view(id);
    }

    @GetMapping("/search")
    public List<CustomerView> search(@RequestParam String name) {
        return service.search(name);
    }

    @PutMapping("/{id}")
    public CustomerView update(@PathVariable UUID id, @RequestBody Customer customer) {
        customer.setId(id);
        return service.save(customer);
    }
}
