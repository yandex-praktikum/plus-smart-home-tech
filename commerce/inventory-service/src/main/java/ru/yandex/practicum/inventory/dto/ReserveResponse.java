package ru.yandex.practicum.inventory.dto;

public record ReserveResponse(

        boolean success,

        Integer availableQuantity,

        String message
) {
}
