## Локальный запуск тестов

### Модуль тестирования:
[hub-router.jar](hub-router.jar)

### Скрипт запуска, указываем имя ветки параметром:
1. Winodws [start-hub-router.bat](local/start-hub-router.bat)
2. Linux [start-hub-router.sh](local/start-hub-router.sh)

### Для ТЗ19 (1-collector-json):
`java -jar hub-router.jar --hub-router.execution.collector.mode=http --hub-router.execution.collector.port=8080`


### Для темы gRPC (2-collector-grpc):
`java -jar hub-router.jar`

### Для темы консьюмер (3-aggregator):
`java -jar hub-router.jar --hub-router.execution.mode=AGGREGATION`

### Для ТЗ20 (4-analyzer):
`java -jar hub-router.jar --hub-router.execution.mode=ANALYZE`

### Какие опции можно указать:
* **grpc.server.port** - gRpc порт Hub Router'а (по умолчанию: 59090)
* **grpc.client.collector.address** - адрес gRPC сервиса коллектора (по умолчанию: static://localhost:${hub-router.execution.collector.port})
* **hub-router.execution.collector.port** - порт коллектора (по умолчанию: 59091)
* **hub-router.execution.mode** - режим работы Hub Router'а (по умолчанию COLLECTION):
  * COLLECTION - проверяется только приём коллектором и запись в кафку
  * AGGREGATION - дполнительно к коллектору, проверяется работа аггрегатора
  * ANALYZE - подолнительно к предыдущем проверяется работа анализатора (ожидаются команды в рамках сценария)
* **hub-router.execution.collector.mode** - подстройка под режим работы коллектора (по умолчанию: grpc):
  * **http** - Hub Router будет коммуницировать по HTTP, отправляя запросы с JSON
  * **grpc** - Hub Router будет коммуницировать по gRPC, отправляя сообщения в Protobuff
* **hub-router.execution.immediate-logging.enabled** - вывод логов по мере работы (в противовес или в дополнение к выводу финального отчета), по умолчанию true
* **hub-router.execution.output.info-enabled** - выводить инфо о ходе выполнения. Если выставить в false будут выводится только ошибки (по умолчанию true)
* **hub-router.execution.output.trace-enabled** - выводить подробные сообщения о ходе выполнения (по умолчанию true)
* **hub-router.execution.output.print** - выводить ли финальный отчёт о выполнении в консоль (по умолчанию true)
* **hub-router.execution.output.file** - сохранять ли финальный отчёт о выполнении в файл (по умолчанию false)
* **hub-router.execution.output.file-path** - путь к файлу для сохранения отчет (по умолчанию: ./execution-report.txt)

## Дополнительно можно переопределить уровни логгеров:
* --logging.level.ru.yandex.practicum=TRACE
* --logging.level.['Лог выполнения']=TRACE