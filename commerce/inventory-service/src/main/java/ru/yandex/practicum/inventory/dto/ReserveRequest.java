package ru.yandex.practicum.inventory.dto;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

public record ReserveRequest(

        @NotNull(message = "ID товара обязателен")
        Long productId,

        @NotNull(message = "Количество обязательно")
        @Min(value = 1, message = "Количество должно быть не менее 1")
        Integer quantity
) {
}
