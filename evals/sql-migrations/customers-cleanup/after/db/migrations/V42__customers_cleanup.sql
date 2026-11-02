-- Customers cleanup: legacy phone column is no longer shown in the UI.
ALTER TABLE customers DROP COLUMN legacy_phone;

-- Everyone must re-accept the new terms.
UPDATE customers SET terms_accepted_at = NULL;

CREATE INDEX idx_customers_email ON customers (lower(email));
