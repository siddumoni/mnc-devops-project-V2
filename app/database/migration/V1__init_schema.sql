-- Reference copy — actual Flyway file used by the app is in
-- app/backend/src/main/resources/db/migration/V1__init_schema.sql
-- This copy is here for teammates who want to inspect the schema
-- without opening the Java project structure.

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

INSERT IGNORE INTO products (name, description, price, stock_quantity) VALUES
    ('Laptop Pro 15',       'High-performance laptop for developers',  89999.00, 50),
    ('Wireless Mouse',      'Ergonomic wireless mouse',                 1299.00, 200),
    ('USB-C Hub',           '7-in-1 USB-C hub with 4K HDMI',           3499.00, 150),
    ('Mechanical Keyboard', 'Tenkeyless mechanical keyboard',           5999.00,  75),
    ('Monitor 27"',         '4K IPS display, 144Hz',                  32999.00,  30);
