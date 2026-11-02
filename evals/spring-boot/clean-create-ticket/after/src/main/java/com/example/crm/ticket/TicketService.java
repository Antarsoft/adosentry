package com.example.crm.ticket;

import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class TicketService {

    private final TicketRepository tickets;
    private final TicketEventRepository events;

    public TicketService(TicketRepository tickets, TicketEventRepository events) {
        this.tickets = tickets;
        this.events = events;
    }

    @Transactional
    public TicketView create(UUID tenantId, UUID agentId, String subject, String body) {
        Ticket ticket = tickets.save(Ticket.open(tenantId, agentId, subject, body == null ? "" : body));
        events.save(TicketEvent.created(ticket.getId(), agentId));
        return TicketView.from(ticket);
    }
}
