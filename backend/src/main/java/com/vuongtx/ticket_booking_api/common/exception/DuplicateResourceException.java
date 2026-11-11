package com.vuongtx.ticket_booking_api.common.exception;

public class DuplicateResourceException extends RuntimeException {

    public DuplicateResourceException(String resource, String field, Object value) {
        super("%s with %s '%s' already exists".formatted(resource, field, value));
    }
}
