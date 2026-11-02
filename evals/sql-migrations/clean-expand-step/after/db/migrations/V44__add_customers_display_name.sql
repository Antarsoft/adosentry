-- Expand step: display_name replaces full_name. The app writes both from release 3.9;
-- a later migration backfills in batches and then drops full_name.
SET lock_timeout = '5s';

ALTER TABLE customers ADD COLUMN IF NOT EXISTS display_name text;

ALTER TABLE customers
    ADD CONSTRAINT chk_customers_display_name_length CHECK (char_length(display_name) <= 120) NOT VALID;
