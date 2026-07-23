package ru.yandex.practicum.order.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;

public record OrderItemRequest(

        @NotNull(message = "ID товара обязателен")
        Long productId,

        @NotBlank(message = "Название товара обязательно")
        String productName,

        @NotNull(message = "Количество обязательно")
        @Min(value = 1, message = "Количество должно быть не менее 1")
        Integer quantity,

        @NotNull(message = "Цена обязательна")
        @DecimalMin(value = "0.01", message = "Цена должна быть больше нуля")
        BigDecimal price
) {
}
