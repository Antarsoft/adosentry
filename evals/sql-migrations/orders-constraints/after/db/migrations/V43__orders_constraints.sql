ALTER TABLE orders ALTER COLUMN reference TYPE varchar(16);

ALTER TABLE orders
    ADD CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id);
