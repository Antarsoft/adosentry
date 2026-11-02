package com.example.crm.ticket;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/tickets")
@PreAuthorize("hasRole('AGENT')")
public class TicketController {

    public record CreateTicketRequest(@NotBlank @Size(max = 120) String subject, @Size(max = 5000) String body) {}

    private final TicketService service;

    public TicketController(TicketService service) {
        this.service = service;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public TicketView create(@Valid @RequestBody CreateTicketRequest request, @AuthenticationPrincipal AgentPrincipal agent) {
        return service.create(agent.tenantId(), agent.id(), request.subject(), request.body());
    }
}
