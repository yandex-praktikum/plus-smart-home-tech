package ru.yandex.practicum.inventory.dto;

public record InventoryDto(

        Long id,

        Long productId,

        Integer quantity,

        Integer reservedQuantity,

        Integer availableQuantity
) {
}
