package ru.yandex.practicum.order.dto;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

public record OrderDto(

        Long id,

        String customerName,

        String customerEmail,

        String status,

        BigDecimal totalPrice,

        String statusDetails,

        LocalDateTime createdAt,

        List<OrderItemDto> items
) {
}
