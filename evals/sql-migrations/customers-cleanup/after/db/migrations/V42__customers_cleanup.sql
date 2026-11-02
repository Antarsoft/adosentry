-- Customers cleanup: legacy phone column is no longer shown in the UI.
ALTER TABLE customers DROP COLUMN legacy_phone;

-- Deactivate customers who have never logged in.
UPDATE customers SET status = 'inactive';

CREATE INDEX idx_customers_email ON customers (lower(email));
