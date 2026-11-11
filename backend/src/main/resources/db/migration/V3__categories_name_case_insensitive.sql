ALTER TABLE categories DROP CONSTRAINT categories_name_key;
CREATE UNIQUE INDEX uq_categories_name_lower ON categories (LOWER(name));