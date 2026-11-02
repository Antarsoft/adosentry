CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    customer_id bigint      NOT NULL,
    reference   varchar(64) NOT NULL,
    total_cents bigint      NOT NULL,
    currency    char(3)     NOT NULL DEFAULT 'EUR',
    created_at  timestamptz NOT NULL DEFAULT now()
);
