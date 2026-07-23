package ru.yandex.practicum.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;

import java.util.List;

public record CreateOrderRequest(

        @NotBlank(message = "Имя покупателя обязательно")
        String customerName,

        @NotBlank(message = "Email обязателен")
        @Email(message = "Некорректный формат email")
        String customerEmail,

        @NotEmpty(message = "Заказ должен содержать хотя бы один товар")
        @Valid
        List<OrderItemRequest> items
) {
}