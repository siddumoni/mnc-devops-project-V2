-- ─────────────────────────────────────────────────────────────────────────────
-- Flyway Migration: V1__init_schema.sql
--
-- Flyway runs this automatically on Spring Boot startup.
-- It checks the flyway_schema_history table — if V1 has not been applied,
-- it applies it now. If it has already been applied, it skips it.
-- This means the schema is always up to date without any manual SQL runs.
--
-- NEVER edit this file after it has been applied to any environment.
-- For schema changes, create V2__description.sql, V3__description.sql etc.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS products (
    id               BIGINT        NOT NULL AUTO_INCREMENT,
    name             VARCHAR(100)  NOT NULL,
    description      VARCHAR(500),
    price            DECIMAL(10,2) NOT NULL,
    stock_quantity   INT           NOT NULL DEFAULT 0,
    created_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Seed data — INSERT IGNORE is safe to run multiple times
INSERT IGNORE INTO products (name, description, price, stock_quantity) VALUES
    ('Laptop Pro 15',       'High-performance laptop for developers',  89999.00, 50),
    ('Wireless Mouse',      'Ergonomic wireless mouse',                 1299.00, 200),
    ('USB-C Hub',           '7-in-1 USB-C hub with 4K HDMI',           3499.00, 150),
    ('Mechanical Keyboard', 'Tenkeyless mechanical keyboard',           5999.00,  75),
    ('Monitor 27"',         '4K IPS display, 144Hz',                  32999.00,  30);
