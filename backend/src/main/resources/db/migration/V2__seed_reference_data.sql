-- =====================================================================
-- Event Ticket Booking System — V2: Reference data
-- Location : src/main/resources/db/migration/V2__seed_reference_data.sql
-- Chỉ seed dữ liệu tham chiếu cần cho mọi môi trường.
-- Dữ liệu demo (user, venue, event mẫu) nên đặt ở migration riêng chỉ chạy cho profile dev.
-- =====================================================================

INSERT INTO roles (name)
VALUES ('CUSTOMER'), ('ORGANIZER'), ('ADMIN');

INSERT INTO categories (name, description)
VALUES
    ('Concert',    'Live music and concerts'),
    ('Conference', 'Conferences and seminars'),
    ('Cinema',     'Movie screenings'),
    ('Theater',    'Theater performances');

INSERT INTO seat_categories (name, description)
VALUES
    ('STANDARD', 'Standard seating'),
    ('PREMIUM',  'Premium seating'),
    ('VIP',      'VIP seating');
