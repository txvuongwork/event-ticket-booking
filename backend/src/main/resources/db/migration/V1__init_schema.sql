-- =====================================================================
-- Event Ticket Booking System — V1: Initial schema
-- Database : PostgreSQL 14+
-- Location : src/main/resources/db/migration/V1__init_schema.sql
--
-- Nguyên tắc:
--   * DB giữ data integrity (PK, FK, UNIQUE, CHECK, partial/exclusion constraint).
--   * Business logic (hold, payment, expire, phát vé, ownership...) nằm ở service layer.
--   * updated_at được cập nhật bởi JPA (@UpdateTimestamp), không dùng trigger.
-- =====================================================================

-- Cần cho exclusion constraint (venue_id WITH =) trên GiST index
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =====================================================================
-- 1. AUTH & USERS
-- =====================================================================

CREATE TABLE users (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name       VARCHAR(100) NOT NULL,
    email           VARCHAR(255) NOT NULL,
    password_hash   VARCHAR(255) NOT NULL,
    phone           VARCHAR(20) UNIQUE,
    status          VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_users_status
        CHECK (status IN ('ACTIVE', 'INACTIVE', 'BANNED'))
);

-- Email unique không phân biệt hoa thường.
-- Lưu ý: query tìm user theo email phải dùng LOWER(email) = LOWER(:email)
-- (hoặc normalize email về lowercase ở service trước khi lưu).
CREATE UNIQUE INDEX uq_users_email_lower ON users (LOWER(email));

CREATE TABLE roles (
    id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE user_roles (
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id BIGINT NOT NULL REFERENCES roles(id),
    PRIMARY KEY (user_id, role_id)
);

-- Chỉ lưu HASH của refresh token (SHA-256), không lưu token gốc.
CREATE TABLE refresh_tokens (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  VARCHAR(255) NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ  NOT NULL,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_refresh_tokens_expiry CHECK (expires_at > created_at)
);


-- =====================================================================
-- 2. CATALOG: CATEGORIES, VENUES, SEATS
-- =====================================================================

CREATE TABLE categories (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE venues (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    address     TEXT,
    city        VARCHAR(100),
    -- Sức chứa khai báo. Số ghế thực tế = COUNT(venue_seats); service nên đảm bảo không vượt capacity.
    capacity    INT          NOT NULL CHECK (capacity > 0),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE seat_categories (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(50) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE venue_seats (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id            BIGINT       NOT NULL REFERENCES venues(id),
    seat_category_id    BIGINT       NOT NULL REFERENCES seat_categories(id),
    seat_row            VARCHAR(10)  NOT NULL,
    seat_number         VARCHAR(10)  NOT NULL,
    x_position          NUMERIC(8,2),
    y_position          NUMERIC(8,2),
    is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_venue_seats_position UNIQUE (venue_id, seat_row, seat_number)
);


-- =====================================================================
-- 3. EVENTS & SESSIONS
-- =====================================================================

CREATE TABLE events (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organizer_id    BIGINT       NOT NULL REFERENCES users(id),
    category_id     BIGINT       NOT NULL REFERENCES categories(id),
    title           VARCHAR(255) NOT NULL,
    description     TEXT,
    thumbnail_url   TEXT,
    status          VARCHAR(20)  NOT NULL DEFAULT 'DRAFT',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_events_status
        CHECK (status IN ('DRAFT', 'PUBLISHED', 'CANCELLED', 'COMPLETED'))
);

CREATE TABLE event_sessions (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id        BIGINT       NOT NULL REFERENCES events(id),
    venue_id        BIGINT       NOT NULL REFERENCES venues(id),
    start_time      TIMESTAMPTZ  NOT NULL,
    end_time        TIMESTAMPTZ  NOT NULL,
    sales_start_at  TIMESTAMPTZ  NOT NULL,
    sales_end_at    TIMESTAMPTZ  NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'SCHEDULED',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_sessions_status
        CHECK (status IN ('SCHEDULED', 'ON_SALE', 'SOLD_OUT', 'CANCELLED', 'COMPLETED')),
    CONSTRAINT chk_sessions_time
        CHECK (end_time > start_time),
    CONSTRAINT chk_sessions_sales_window
        CHECK (sales_end_at > sales_start_at),
    -- Không bán vé sau khi suất diễn đã bắt đầu
    CONSTRAINT chk_sessions_sales_before_start
        CHECK (sales_end_at <= start_time),
    -- Hai suất diễn chưa bị huỷ không được trùng giờ tại cùng một venue
    CONSTRAINT ex_sessions_venue_overlap
        EXCLUDE USING gist (
            venue_id WITH =,
            tstzrange(start_time, end_time, '[)') WITH &&
        ) WHERE (status <> 'CANCELLED')
);

CREATE TABLE event_session_seat_prices (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_session_id    BIGINT        NOT NULL REFERENCES event_sessions(id),
    seat_category_id    BIGINT        NOT NULL REFERENCES seat_categories(id),
    price               NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_session_seat_category UNIQUE (event_session_id, seat_category_id)
);


-- =====================================================================
-- 4. BOOKINGS & SEAT HOLDS
-- =====================================================================

CREATE TABLE bookings (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_code        VARCHAR(50)   NOT NULL UNIQUE,
    user_id             BIGINT        NOT NULL REFERENCES users(id),
    event_session_id    BIGINT        NOT NULL REFERENCES event_sessions(id),
    total_amount        NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
    status              VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
    expires_at          TIMESTAMPTZ,
    -- Optimistic locking (@Version): chống race giữa payment callback và expire job
    version             BIGINT        NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_bookings_status
        CHECK (status IN ('PENDING', 'CONFIRMED', 'EXPIRED', 'CANCELLED', 'FAILED')),
    -- Booking đang PENDING bắt buộc phải có hạn giữ chỗ
    CONSTRAINT chk_bookings_pending_has_expiry
        CHECK (status <> 'PENDING' OR expires_at IS NOT NULL),
    -- Phục vụ composite FK từ booking_seats
    CONSTRAINT uq_bookings_id_session UNIQUE (id, event_session_id)
);

CREATE TABLE booking_seats (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id          BIGINT        NOT NULL,
    event_session_id    BIGINT        NOT NULL REFERENCES event_sessions(id),
    venue_seat_id       BIGINT        NOT NULL REFERENCES venue_seats(id),
    -- Price snapshot tại thời điểm hold, không đổi khi bảng giá thay đổi
    price               NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    status              VARCHAR(20)   NOT NULL DEFAULT 'HELD',
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_booking_seats_status
        CHECK (status IN ('HELD', 'BOOKED', 'RELEASED')),
    -- Đảm bảo booking_seats.event_session_id luôn khớp với bookings.event_session_id
    CONSTRAINT fk_booking_seats_booking_session
        FOREIGN KEY (booking_id, event_session_id)
        REFERENCES bookings (id, event_session_id)
    -- Lưu ý: việc ghế (venue_seat_id) thuộc đúng venue của session
    -- được validate ở service layer.
);

-- Mỗi ghế trong một suất diễn chỉ có tối đa 1 bản ghi đang HELD hoặc BOOKED.
-- Ghế hết hạn hold phải được chuyển sang RELEASED (bởi scheduled job) mới hold lại được.
CREATE UNIQUE INDEX uq_active_session_seat
    ON booking_seats (event_session_id, venue_seat_id)
    WHERE status IN ('HELD', 'BOOKED');


-- =====================================================================
-- 5. PAYMENTS
-- =====================================================================

CREATE TABLE payments (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id          BIGINT        NOT NULL REFERENCES bookings(id),
    -- Client gửi kèm header Idempotency-Key; gửi lại cùng key thì trả về kết quả cũ
    idempotency_key     VARCHAR(100)  NOT NULL UNIQUE,
    transaction_code    VARCHAR(100)  UNIQUE,
    amount              NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    payment_method      VARCHAR(30)   NOT NULL DEFAULT 'MOCK',
    status              VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
    paid_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_payments_status
        CHECK (status IN ('PENDING', 'SUCCESS', 'FAILED', 'REFUNDED')),
    CONSTRAINT chk_payments_method
        CHECK (payment_method IN ('MOCK')),
    -- Payment thành công phải có thời điểm thanh toán
    CONSTRAINT chk_payments_success_paid_at
        CHECK (status NOT IN ('SUCCESS', 'REFUNDED') OR paid_at IS NOT NULL)
);

-- Một booking chỉ có tối đa 1 payment thành công
CREATE UNIQUE INDEX uq_payment_success_per_booking
    ON payments (booking_id)
    WHERE status = 'SUCCESS';


-- =====================================================================
-- 6. TICKETS
-- =====================================================================

CREATE TABLE tickets (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_code         VARCHAR(50)  NOT NULL UNIQUE,
    booking_seat_id     BIGINT       NOT NULL UNIQUE REFERENCES booking_seats(id),
    -- Token ngẫu nhiên, opaque; không encode thông tin cá nhân/thanh toán vào QR
    qr_token            UUID         NOT NULL UNIQUE,
    status              VARCHAR(20)  NOT NULL DEFAULT 'VALID',
    issued_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    checked_in_at       TIMESTAMPTZ,
    CONSTRAINT chk_tickets_status
        CHECK (status IN ('VALID', 'USED', 'CANCELLED')),
    -- Vé đã USED phải có thời điểm check-in
    CONSTRAINT chk_tickets_used_checked_in
        CHECK (status <> 'USED' OR checked_in_at IS NOT NULL)
);


-- =====================================================================
-- 7. AUDIT LOGS
-- =====================================================================

CREATE TABLE audit_logs (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     BIGINT       REFERENCES users(id),
    action      VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50),
    entity_id   BIGINT,
    description TEXT,
    metadata    JSONB,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- =====================================================================
-- 8. INDEXES
-- (Các cột UNIQUE / PK đã tự có index, không tạo lại)
-- =====================================================================

-- Auth
CREATE INDEX idx_refresh_tokens_user          ON refresh_tokens (user_id);

-- Events & sessions
CREATE INDEX idx_events_organizer             ON events (organizer_id);
CREATE INDEX idx_events_category              ON events (category_id);
CREATE INDEX idx_sessions_event_start         ON event_sessions (event_id, start_time);
CREATE INDEX idx_sessions_venue               ON event_sessions (venue_id);
CREATE INDEX idx_sessions_start_time          ON event_sessions (start_time);

-- Bookings
CREATE INDEX idx_bookings_user                ON bookings (user_id, created_at DESC);
CREATE INDEX idx_bookings_session_status      ON bookings (event_session_id, status);
-- Phục vụ scheduled job quét booking hết hạn
CREATE INDEX idx_bookings_expiration          ON bookings (expires_at)
    WHERE status = 'PENDING';

-- Booking seats
CREATE INDEX idx_booking_seats_booking        ON booking_seats (booking_id);
CREATE INDEX idx_booking_seats_venue_seat     ON booking_seats (venue_seat_id);

-- Payments
CREATE INDEX idx_payments_booking             ON payments (booking_id);

-- Audit logs
CREATE INDEX idx_audit_logs_entity            ON audit_logs (entity_type, entity_id);
CREATE INDEX idx_audit_logs_user_created      ON audit_logs (user_id, created_at DESC);
