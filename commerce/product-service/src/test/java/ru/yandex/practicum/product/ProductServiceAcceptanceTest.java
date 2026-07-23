package ru.yandex.practicum.product;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import ru.yandex.practicum.product.dto.CreateCategoryRequest;
import ru.yandex.practicum.product.dto.CreateProductRequest;
import ru.yandex.practicum.product.dto.UpdateProductRequest;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

@SpringBootTest
@AutoConfigureMockMvc
@SuppressWarnings("unchecked")
class ProductServiceAcceptanceTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private ObjectMapper json;

    @Test
    void shouldCreateCategoryAndProductThenFindProductThroughCatalogEndpoints() throws Exception {
        CreateCategoryRequest categoryRequest = new CreateCategoryRequest(
                "Acceptance category",
                "Категория для проверки REST-контракта"
        );

        MvcResult categoryResponse = postJson("/api/categories", categoryRequest);

        assertThat(status(categoryResponse))
                .as("POST /api/categories должен создавать категорию и возвращать HTTP 201 Created")
                .isEqualTo(201);
        Map<String, Object> category = readMap(categoryResponse);
        Long categoryId = asLong(category.get("id"));
        assertThat(categoryId)
                .as("Созданная категория должна содержать поле id")
                .isNotNull();
        assertThat(category.get("name"))
                .as("Созданная категория должна возвращать переданное название")
                .isEqualTo("Acceptance category");

        MvcResult categoryByIdResponse = mvc.perform(get("/api/categories/{id}", categoryId)).andReturn();

        assertThat(status(categoryByIdResponse))
                .as("GET /api/categories/{id} должен возвращать созданную категорию")
                .isEqualTo(200);
        assertThat(asLong(readMap(categoryByIdResponse).get("id")))
                .as("GET /api/categories/{id} должен вернуть категорию с запрошенным id")
                .isEqualTo(categoryId);

        CreateProductRequest productRequest = new CreateProductRequest(
                "Acceptance Smart Lamp",
                "Лампа для проверки REST-контракта",
                new BigDecimal("3490.00"),
                categoryId,
                "https://example.com/lamp.png"
        );

        MvcResult productResponse = postJson("/api/products", productRequest);

        assertThat(status(productResponse))
                .as("POST /api/products должен создавать товар и возвращать HTTP 201 Created")
                .isEqualTo(201);
        Map<String, Object> product = readMap(productResponse);
        Long productId = asLong(product.get("id"));
        assertThat(productId)
                .as("Созданный товар должен содержать поле id")
                .isNotNull();
        assertThat(product.get("name"))
                .as("Созданный товар должен возвращать переданное название")
                .isEqualTo("Acceptance Smart Lamp");
        assertThat(asDecimal(product.get("price")))
                .as("Созданный товар должен возвращать переданную цену")
                .isEqualByComparingTo("3490.00");

        MvcResult productByIdResponse = mvc.perform(get("/api/products/{id}", productId)).andReturn();

        assertThat(status(productByIdResponse))
                .as("GET /api/products/{id} должен возвращать созданный товар")
                .isEqualTo(200);
        assertThat(readMap(productByIdResponse).get("name"))
                .as("GET /api/products/{id} должен вернуть товар с ожидаемым названием")
                .isEqualTo("Acceptance Smart Lamp");

        MvcResult searchResponse = mvc.perform(get("/api/products/search").param("query", "Lamp")).andReturn();

        assertThat(status(searchResponse))
                .as("GET /api/products/search?query=... должен выполнять поиск товаров")
                .isEqualTo(200);
        assertThat(readList(searchResponse))
                .as("Поиск по части названия должен вернуть созданный товар")
                .anySatisfy(item -> assertThat(item).containsEntry("name", "Acceptance Smart Lamp"));

        MvcResult patchResponse = mvc.perform(patch("/api/products/{id}", productId)
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(new UpdateProductRequest(
                        "Acceptance Smart Lamp v2",
                        null,
                        new BigDecimal("3990.00"),
                        null,
                        null,
                        true
                )))).andReturn();

        assertThat(status(patchResponse))
                .as("PATCH /api/products/{id} должен успешно обновлять товар")
                .isEqualTo(200);

        MvcResult updatedProductResponse = mvc.perform(get("/api/products/{id}", productId)).andReturn();
        Map<String, Object> updatedProduct = readMap(updatedProductResponse);
        assertThat(updatedProduct.get("name"))
                .as("PATCH /api/products/{id} должен частично обновлять поля товара")
                .isEqualTo("Acceptance Smart Lamp v2");
        assertThat(asDecimal(updatedProduct.get("price")))
                .as("PATCH /api/products/{id} должен обновлять цену товара")
                .isEqualByComparingTo("3990.00");
    }

    @Test
    void shouldReturnBadRequestForInvalidProductPayload() throws Exception {
        CreateProductRequest invalidRequest = new CreateProductRequest(
                "",
                "Некорректный товар без названия и цены",
                null,
                null,
                null
        );

        MvcResult response = postJson("/api/products", invalidRequest);

        assertThat(status(response))
                .as("POST /api/products с невалидным телом запроса должен возвращать HTTP 400 Bad Request")
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

    private List<Map<String, Object>> readList(MvcResult result) throws Exception {
        return json.readValue(result.getResponse().getContentAsString(), new TypeReference<>() {
        });
    }

    private static Long asLong(Object value) {
        return value == null ? null : ((Number) value).longValue();
    }

    private static BigDecimal asDecimal(Object value) {
        return new BigDecimal(value.toString());
    }
}