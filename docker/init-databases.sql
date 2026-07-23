-- Скрипт автоматически выполняется при первом запуске контейнера PostgreSQL.
-- Создаёт три базы данных для бизнес-сервисов (database-per-service pattern).

CREATE DATABASE product_db;
CREATE DATABASE inventory_db;
CREATE DATABASE order_db;
