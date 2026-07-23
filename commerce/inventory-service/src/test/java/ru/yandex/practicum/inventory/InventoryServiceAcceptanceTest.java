package ru.yandex.practicum.inventory;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import ru.yandex.practicum.inventory.dto.ReserveRequest;
import ru.yandex.practicum.inventory.dto.UpdateInventoryRequest;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

@SpringBootTest
@AutoConfigureMockMvc
@SuppressWarnings("unchecked")
class InventoryServiceAcceptanceTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private ObjectMapper json;

    @Test
    void shouldCreateUpdateReadAndReserveInventoryRecord() throws Exception {
        long productId = 100_001L;

        MvcResult createResponse = postJson("/api/inventory", new UpdateInventoryRequest(productId, 10));

        assertThat(status(createResponse))
                .as("POST /api/inventory должен создавать складскую запись и возвращать HTTP 201 Created")
                .isEqualTo(201);
        Map<String, Object> created = readMap(createResponse);
        assertThat(asLong(created.get("productId")))
                .as("Созданная складская запись должна относиться к переданному productId")
                .isEqualTo(productId);
        assertThat(asInt(created.get("quantity")))
                .as("Созданная складская запись должна хранить общее количество товара")
                .isEqualTo(10);
        assertThat(asInt(created.get("reservedQuantity")))
                .as("У новой складской записи зарезервированное количество должно быть равно 0")
                .isZero();
        assertThat(asInt(created.get("availableQuantity")))
                .as("Доступное количество должно вычисляться как quantity - reservedQuantity")
                .isEqualTo(10);

        MvcResult updateResponse = mvc.perform(put("/api/inventory")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(new UpdateInventoryRequest(productId, 15))))
                .andReturn();

        assertThat(status(updateResponse))
                .as("PUT /api/inventory должен обновлять существующую складскую запись")
                .isEqualTo(200);

        MvcResult updatedResponse = mvc.perform(get("/api/inventory/{productId}", productId)).andReturn();

        assertThat(status(updatedResponse))
                .as("GET /api/inventory/{productId} должен возвращать складскую запись по productId")
                .isEqualTo(200);
        Map<String, Object> updated = readMap(updatedResponse);
        assertThat(asInt(updated.get("quantity")))
                .as("PUT /api/inventory должен обновлять общее количество товара")
                .isEqualTo(15);
        assertThat(asInt(updated.get("availableQuantity")))
                .as("После обновления доступное количество должно быть пересчитано")
                .isEqualTo(15);

        MvcResult reserveResponse = postJson("/api/inventory/reserve", new ReserveRequest(productId, 4));

        assertThat(status(reserveResponse))
                .as("POST /api/inventory/reserve должен резервировать доступный товар")
                .isEqualTo(200);
        Map<String, Object> reserve = readMap(reserveResponse);
        assertThat(reserve.get("success"))
                .as("При успешном резервировании поле success должно быть true")
                .isEqualTo(true);
        assertThat(asInt(reserve.get("availableQuantity")))
                .as("После резервирования доступное количество должно уменьшиться")
                .isEqualTo(11);
    }

    @Test
    void shouldReturnConflictWhenReservationExceedsAvailableQuantity() throws Exception {
        long productId = 100_002L;
        postJson("/api/inventory", new UpdateInventoryRequest(productId, 2));

        MvcResult response = postJson("/api/inventory/reserve", new ReserveRequest(productId, 3));

        assertThat(status(response))
                .as("POST /api/inventory/reserve должен возвращать HTTP 409 Conflict, если товара недостаточно")
                .isEqualTo(409);
        assertThat(readMap(response))
                .as("Ответ ошибки должен содержать понятное сообщение")
                .containsKey("message");
    }

    @Test
    void shouldReturnBadRequestForInvalidInventoryPayload() throws Exception {
        MvcResult response = postJson("/api/inventory", new UpdateInventoryRequest(null, -1));

        assertThat(status(response))
                .as("POST /api/inventory с невалидным телом запроса должен возвращать HTTP 400 Bad Request")
                .isEqualTo(400);
        assertThat(readMap(response))
                .as("Ответ ошибки должен содержать сообщение и детали валидации")
                .containsKeys("message", "validationErrors");
    }

    private MvcResult postJson(String url, Object body) throws Exception {
        return mvc.perform(post(url)
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body)))
                .andReturn();
    }

    private static int status(MvcResult result) {
        return result.getResponse().getStatus();
    }

    private Map<String, Object> readMap(MvcResult result) throws Exception {
        return json.readValue(result.getResponse().getContentAsString(), new TypeReference<>() {
        });
    }

    private static Long asLong(Object value) {
        return value == null ? null : ((Number) value).longValue();
    }

    private static Integer asInt(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }
}
