terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = "4.7.0"
    }
  }
}

variable "aiven_api_token" {
  type = string
}

variable "aiven_project_name" {
  type = string
}

locals {
  cloud_name                                             = "aws-ap-southeast-1"
  data_pipeline_prefix                                   = "data-pipeline"
  service_name_prefix                                    = "test-dvd-rental"
  increment_source_kafka_connector_name                  = "jdbc_source_pg_increment"
  film_category_timestamp_source_kafka_connector_name    = "jdbc_source_pg_film_category_timestamp"
  payment_timestamp_source_kafka_connector_name          = "jdbc_source_pg_partitioned_payment"
  api_url                                                = "https://console.aiven.io"
}

provider "aiven" {
  api_token = var.aiven_api_token
}

resource "aiven_pg" "pg" {
  project      = var.aiven_project_name
  cloud_name   = local.cloud_name
  plan         = "startup-4"
  service_name = "${local.data_pipeline_prefix}-${local.service_name_prefix}-pg"

  tag {
    key   = local.data_pipeline_prefix
    value = local.service_name_prefix
  }
}

resource "null_resource" "load_sample_data" {
  depends_on = [aiven_pg.pg]

  provisioner "local-exec" {
    command = <<EOT
        curl '${local.api_url}/v1/project/${var.aiven_project_name}/service/${aiven_pg.pg.service_name}/task' \
            -H 'content-type: application/json' \
            -H 'authorization: aivenv1 ${var.aiven_api_token}' \
            --data-raw '{"task_type":"dataset_import","dataset_import":{"dataset_name":"pagila"}}'
        EOT
  }

  # Wait 30 seconds for the pagila database to be created.
  provisioner "local-exec" {
    command = "sleep 30"
  }
}

data "aiven_pg_database" "pagila" {
  depends_on    = [null_resource.load_sample_data]
  project       = var.aiven_project_name
  service_name  = aiven_pg.pg.service_name
  database_name = "pagila"
}

resource "aiven_kafka" "kafka" {
  project      = var.aiven_project_name
  service_name = "${local.data_pipeline_prefix}-${local.service_name_prefix}-kafka"
  cloud_name   = local.cloud_name
  plan         = "business-4"

  kafka_user_config {
    kafka_connect = true
    kafka_rest    = true
  }

  tag {
    key   = local.data_pipeline_prefix
    value = local.service_name_prefix
  }
}

resource "time_sleep" "wait_for_kafka_connect" {
  depends_on       = [aiven_kafka.kafka]
  create_duration  = "180s"
}

resource "aiven_kafka_connector" "jdbc_source_pg_increment" {
  depends_on     = [data.aiven_pg_database.pagila, time_sleep.wait_for_kafka_connect]
  project        = var.aiven_project_name
  service_name   = aiven_kafka.kafka.service_name
  connector_name = local.increment_source_kafka_connector_name

  config = {
    "connection.url": "jdbc:postgresql://${aiven_pg.pg.service_host}:${aiven_pg.pg.service_port}/pagila?sslmode=require",
    "connection.user": "${aiven_pg.pg.service_username}",
    "poll.interval.ms": "2000",
    "connector.class": "io.aiven.connect.jdbc.JdbcSourceConnector",
    "connection.password": "${aiven_pg.pg.service_password}",
    "name": "${local.increment_source_kafka_connector_name}",
    "mode": "incrementing",
    "topic.prefix": "${local.increment_source_kafka_connector_name}.",
    "table.whitelist": "rental,store,inventory,film,address,city,customer,language,country,category",
    "numeric.mapping": "best_fit",
  }
}

resource "aiven_kafka_connector" "jdbc_source_pg_film_category_timestamp" {
  depends_on     = [data.aiven_pg_database.pagila, time_sleep.wait_for_kafka_connect]
  project        = var.aiven_project_name
  service_name   = aiven_kafka.kafka.service_name
  connector_name = local.film_category_timestamp_source_kafka_connector_name

  config = {
    "connection.url": "jdbc:postgresql://${aiven_pg.pg.service_host}:${aiven_pg.pg.service_port}/pagila?sslmode=require",
    "connection.user": "${aiven_pg.pg.service_username}",
    "poll.interval.ms": "2000",
    "connector.class": "io.aiven.connect.jdbc.JdbcSourceConnector",
    "connection.password": "${aiven_pg.pg.service_password}",
    "name": "${local.film_category_timestamp_source_kafka_connector_name}",
    "topic.prefix": "${local.film_category_timestamp_source_kafka_connector_name}.",
    "mode": "timestamp",
    "timestamp.column.name": "last_update",
    "table.whitelist": "film_category",
  }
}

resource "aiven_kafka_connector" "jdbc_source_pg_partitioned_payment" {
  depends_on     = [data.aiven_pg_database.pagila, time_sleep.wait_for_kafka_connect]
  project        = var.aiven_project_name
  service_name   = aiven_kafka.kafka.service_name
  connector_name = local.payment_timestamp_source_kafka_connector_name

  config = {
    "connection.url": "jdbc:postgresql://${aiven_pg.pg.service_host}:${aiven_pg.pg.service_port}/pagila?sslmode=require",
    "connection.user": "${aiven_pg.pg.service_username}",
    "poll.interval.ms": "2000",
    "connector.class": "io.aiven.connect.jdbc.JdbcSourceConnector",
    "connection.password": "${aiven_pg.pg.service_password}",
    "name": "${local.payment_timestamp_source_kafka_connector_name}",
    "topic.prefix": "${local.payment_timestamp_source_kafka_connector_name}.",
    "mode": "timestamp",
    "timestamp.column.name": "payment_date",
    "table.whitelist": "payment_p2020_01,payment_p2020_02,payment_p2020_03,payment_p2020_04,payment_p2020_05",
    "numeric.mapping": "best_fit",
  }
}

resource "aiven_kafka_topic" "rental_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.rental"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "store_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.store"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "inventory_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.inventory"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "film_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.film"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "address_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.address"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "city_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.city"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "customer_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.customer"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "language_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.language"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "country_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.country"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "film_category_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.film_category_timestamp_source_kafka_connector_name}.film_category"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "category_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.increment_source_kafka_connector_name}.category"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "payment_p2020_01_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.payment_timestamp_source_kafka_connector_name}.payment_p2020_01"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "payment_p2020_02_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.payment_timestamp_source_kafka_connector_name}.payment_p2020_02"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "payment_p2020_03_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.payment_timestamp_source_kafka_connector_name}.payment_p2020_03"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "payment_p2020_04_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.payment_timestamp_source_kafka_connector_name}.payment_p2020_04"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "payment_p2020_05_source" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "${local.payment_timestamp_source_kafka_connector_name}.payment_p2020_05"
  partitions   = 1
  replication  = 2
}

resource "aiven_kafka_topic" "aggregated_rental_sink" {
  project      = var.aiven_project_name
  service_name = aiven_kafka.kafka.service_name
  topic_name   = "aggregated_rental_sink"
  partitions   = 1
  replication  = 2
}

resource "aiven_flink" "flink" {
  project      = var.aiven_project_name
  cloud_name   = local.cloud_name
  plan         = "business-4"
  service_name = "${local.data_pipeline_prefix}-${local.service_name_prefix}-flink"

  tag {
    key   = local.data_pipeline_prefix
    value = local.service_name_prefix
  }
}

resource "aiven_service_integration" "flink_to_kafka" {
  project                  = var.aiven_project_name
  integration_type         = "flink"
  destination_service_name = aiven_flink.flink.service_name
  source_service_name      = aiven_kafka.kafka.service_name
}

resource "aiven_flink_application" "rental_aggregator" {
  project      = var.aiven_project_name
  service_name = aiven_flink.flink.service_name
  name         = "rental_aggregator"
}

resource "aiven_flink_application_version" "version_1" {
  depends_on = [aiven_service_integration.flink_to_kafka, aiven_flink_application.rental_aggregator]

  project        = var.aiven_project_name
  service_name   = aiven_flink.flink.service_name
  application_id = aiven_flink_application.rental_aggregator.application_id
  statement      = <<EOT
INSERT INTO kafka_aggregated_rental_sink (
  SELECT
      rental.rental_id,
      TO_TIMESTAMP(FROM_UNIXTIME(rental.rental_date)),
      TO_TIMESTAMP(FROM_UNIXTIME(rental.return_date)),
      CASE WHEN return_date IS NOT NULL THEN TIMESTAMPDIFF(DAY, TO_TIMESTAMP(FROM_UNIXTIME(return_date)), TO_TIMESTAMP(FROM_UNIXTIME(rental_date))) ELSE NULL END AS rental_duration_in_days,
      film.rental_duration AS allowed_rental_duration_in_days,
      film.rental_rate AS rental_rate,
      TO_TIMESTAMP(FROM_UNIXTIME(payment.payment_date)),
      payment.amount AS payment_amount,
      CASE WHEN rental.return_date IS NULL THEN FALSE ELSE TRUE END AS film_returned,
      film.replacement_cost AS film_replacement_cost,
      film.title AS film_title,
      category.name AS film_category,
      film.description AS film_description,
      film.release_year AS film_release_year,
      film_language.name AS film_language,
      film.length AS film_length,
      film.rating AS film_rating,
      store.store_id,
      address.address AS store_address,
      city.city AS store_city,
      address.postal_code AS store_postal_code,
      country.country AS store_country,
      store.manager_staff_id AS store_manager_id,
      rental.customer_id,
      TO_TIMESTAMP(FROM_UNIXTIME(customer.create_date)) AS customer_since,
      customer_city.city AS customer_city
  FROM kafka_rental_source AS rental
  JOIN kafka_customer_source AS customer ON rental.customer_id = customer.customer_id
  JOIN kafka_inventory_source AS inventory ON rental.inventory_id = inventory.inventory_id
  JOIN kafka_store_source AS store ON inventory.store_id = store.store_id
  JOIN kafka_address_source AS address ON store.address_id = address.address_id
  JOIN kafka_city_source AS city ON address.city_id = city.city_id
  JOIN kafka_country_source AS country ON city.country_id = country.country_id
  JOIN kafka_address_source AS customer_address ON customer.address_id = customer_address.address_id
  JOIN kafka_city_source AS customer_city ON customer_address.city_id = customer_city.city_id
  JOIN kafka_film_source AS film ON inventory.film_id = film.film_id
  JOIN kafka_film_category_source AS film_category ON film.film_id = film_category.film_id
  JOIN kafka_category_source AS category ON film_category.category_id = category.category_id
  JOIN kafka_language_source AS film_language ON film.language_id = film_language.language_id
  JOIN (
      SELECT rental_id, amount, payment_date
      FROM kafka_payment_p2020_01_source
      UNION ALL
      SELECT rental_id, amount, payment_date
      FROM kafka_payment_p2020_02_source
      UNION ALL
      SELECT rental_id, amount, payment_date
      FROM kafka_payment_p2020_03_source
      UNION ALL
      SELECT rental_id, amount, payment_date
      FROM kafka_payment_p2020_04_source
      UNION ALL
      SELECT rental_id, amount, payment_date
      FROM kafka_payment_p2020_05_source
  ) AS payment ON rental.rental_id = payment.rental_id
)
  EOT

  sink {
    create_table   = <<EOT
CREATE TABLE kafka_aggregated_rental_sink (
  rental_id INT,
  rental_date TIMESTAMP,
  return_date TIMESTAMP,
  rental_duration_in_days INT,
  allowed_rental_duration_in_days INT,
  rental_rate NUMERIC(4,2),
  payment_date TIMESTAMP,
  payment_amount NUMERIC(5,2),
  film_returned BOOLEAN,
  film_replacement_cost NUMERIC(5,2),
  film_title STRING,
  film_category STRING,
  film_description STRING,
  film_release_year INT,
  film_language STRING,
  film_length INT,
  film_rating STRING,
  store_id INT,
  store_address STRING,
  store_city STRING,
  store_postal_code STRING,
  store_country STRING,
  store_manager_id INT,
  customer_id INT,
  customer_since TIMESTAMP,
  customer_city STRING
) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'aggregated_rental_sink',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_rental_source (
  rental_id INT NOT NULL,
  rental_date BIGINT NOT NULL,
  inventory_id INT NOT NULL,
  customer_id INT NOT NULL,
  return_date BIGINT,
  staff_id INT NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.rental',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_store_source (
  store_id INT NOT NULL,
  manager_staff_id INT NOT NULL,
  address_id INT NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.store',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_inventory_source (
  inventory_id INT NOT NULL,
  film_id INT NOT NULL,
  store_id INT NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.inventory',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_film_source (
  film_id INT NOT NULL,
  title STRING NOT NULL,
  description STRING,
  release_year INT,
  language_id INT NOT NULL,
  original_language_id INT,
  rental_duration INT NOT NULL,
  rental_rate NUMERIC(4,2) NOT NULL,
  length INT,
  replacement_cost NUMERIC(5,2) NOT NULL,
  rating STRING NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.film',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_address_source (
  address_id INT NOT NULL,
  address STRING NOT NULL,
  address2 STRING,
  district STRING NOT NULL,
  city_id INT NOT NULL,
  postal_code STRING,
  phone STRING NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.address',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_city_source (
  city_id INT NOT NULL,
  city STRING NOT NULL,
  country_id INT NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.city',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_customer_source (
  customer_id INT NOT NULL,
  store_id INT NOT NULL,
  first_name STRING NOT NULL,
  last_name STRING NOT NULL,
  email STRING,
  address_id INT NOT NULL,
  activebool BOOLEAN NOT NULL,
  create_date BIGINT NOT NULL,
  last_update BIGINT,
  active INT) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.customer',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_language_source (
  language_id INT NOT NULL,
  name STRING NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.language',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_country_source (
  country_id INT NOT NULL,
  country STRING NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.country',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_film_category_source (
  film_id INT NOT NULL,
  category_id INT NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_film_category_timestamp.film_category',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_category_source (
  category_id INT NOT NULL,
  name STRING NOT NULL,
  last_update BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_increment.category',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_payment_p2020_01_source (
  payment_id INT NOT NULL,
  customer_id INT NOT NULL,
  staff_id INT NOT NULL,
  rental_id INT NOT NULL,
  amount NUMERIC(5,2) NOT NULL,
  payment_date BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_partitioned_payment.payment_p2020_01',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_payment_p2020_02_source (
  payment_id INT NOT NULL,
  customer_id INT NOT NULL,
  staff_id INT NOT NULL,
  rental_id INT NOT NULL,
  amount NUMERIC(5,2) NOT NULL,
  payment_date BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_partitioned_payment.payment_p2020_02',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_payment_p2020_03_source (
  payment_id INT NOT NULL,
  customer_id INT NOT NULL,
  staff_id INT NOT NULL,
  rental_id INT NOT NULL,
  amount NUMERIC(5,2) NOT NULL,
  payment_date BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_partitioned_payment.payment_p2020_03',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_payment_p2020_04_source (
  payment_id INT NOT NULL,
  customer_id INT NOT NULL,
  staff_id INT NOT NULL,
  rental_id INT NOT NULL,
  amount NUMERIC(5,2) NOT NULL,
  payment_date BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_partitioned_payment.payment_p2020_04',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }

  source {
    create_table   = <<EOT
CREATE TABLE kafka_payment_p2020_05_source (
  payment_id INT NOT NULL,
  customer_id INT NOT NULL,
  staff_id INT NOT NULL,
  rental_id INT NOT NULL,
  amount NUMERIC(5,2) NOT NULL,
  payment_date BIGINT NOT NULL) WITH (
  'connector' = 'kafka',
  'properties.bootstrap.servers' = '',
  'scan.startup.mode' = 'earliest-offset',
  'topic' = 'jdbc_source_pg_partitioned_payment.payment_p2020_05',
  'value.format' = 'json'
)
    EOT
    integration_id = aiven_service_integration.flink_to_kafka.integration_id
  }
}

resource "aiven_flink_application_deployment" "flink_application_deployment" {
  project         = var.aiven_project_name
  service_name    = aiven_flink.flink.service_name
  application_id  = aiven_flink_application.rental_aggregator.application_id
  version_id      = aiven_flink_application_version.version_1.application_version_id
  restart_enabled = true
}

resource "aiven_clickhouse" "clickhouse" {
  project      = var.aiven_project_name
  cloud_name   = local.cloud_name
  plan         = "startup-16"
  service_name = "${local.data_pipeline_prefix}-${local.service_name_prefix}-clickhouse"

  tag {
    key   = local.data_pipeline_prefix
    value = local.service_name_prefix
  }
}

resource "aiven_service_integration" "clickhouse_kafka_source" {
  project                  = var.aiven_project_name
  integration_type         = "clickhouse_kafka"
  source_service_name      = aiven_kafka.kafka.service_name
  destination_service_name = aiven_clickhouse.clickhouse.service_name

  clickhouse_kafka_user_config {
    tables {
      name        = "rental_raw"
      group_name  = "clickhouse-ingestion"
      data_format = "JSONEachRow"
      columns {
        name = "rental_id"
        type = "Int"
      }
      columns {
        name = "rental_date"
        type = "DateTime"
      }
      columns {
        name = "return_date"
        type = "DateTime"
      }
      columns {
        name = "rental_duration_in_days"
        type = "Int"
      }
      columns {
        name = "rental_rate"
        type = "Decimal(4,2)"
      }
      columns {
        name = "payment_date"
        type = "DateTime"
      }
      columns {
        name = "payment_amount"
        type = "Decimal(5,2)"
      }
      columns {
        name = "film_returned"
        type = "Boolean"
      }
      columns {
        name = "film_replacement_cost"
        type = "Decimal(5,2)"
      }
      columns {
        name = "film_title"
        type = "LowCardinality(String)"
      }
      columns {
        name = "film_category"
        type = "LowCardinality(String)"
      }
      columns {
        name = "film_description"
        type = "LowCardinality(String)"
      }
      columns {
        name = "film_release_year"
        type = "Int"
      }
      columns {
        name = "film_language"
        type = "LowCardinality(String)"
      }
      columns {
        name = "film_length"
        type = "Int"
      }
      columns {
        name = "film_rating"
        type = "LowCardinality(String)"
      }
      columns {
        name = "store_id"
        type = "Int"
      }
      columns {
        name = "store_address"
        type = "LowCardinality(String)"
      }
      columns {
        name = "store_city"
        type = "LowCardinality(String)"
      }
      columns {
        name = "store_postal_code"
        type = "LowCardinality(String)"
      }
      columns {
        name = "store_country"
        type = "LowCardinality(String)"
      }
      columns {
        name = "store_manager_id"
        type = "Int"
      }
      columns {
        name = "customer_id"
        type = "Int"
      }
      columns {
        name = "customer_since"
        type = "DateTime"
      }
      columns {
        name = "customer_city"
        type = "String"
      }
      topics {
        name = aiven_kafka_topic.aggregated_rental_sink.topic_name
      }
    }
  }
}

resource "null_resource" "create_analytics_table" {
  depends_on = [aiven_service_integration.clickhouse_kafka_source]

  # Wait 5 seconds for the integration table to be running.
  provisioner "local-exec" {
    command = "sleep 5"
  }

  provisioner "local-exec" {
    command = <<EOT
        curl '${local.api_url}/v1/project/${var.aiven_project_name}/service/${aiven_clickhouse.clickhouse.service_name}/clickhouse/query' \
            -H 'content-type: application/json' \
            -H 'authorization: aivenv1 ${var.aiven_api_token}' \
            --data-raw '{"database":"default","query":"\nCREATE TABLE rental_analytics (\n    rental_id Int,\n    rental_date DateTime,\n    return_date DateTime,\n    rental_duration_in_days Int,\n    rental_rate Decimal(4,2),\n    payment_date DateTime,\n    payment_amount Decimal(5,2),\n    film_returned Boolean,\n    film_replacement_cost Decimal(5,2),\n    film_title LowCardinality(String),\n    film_category LowCardinality(String),\n    film_description LowCardinality(String),\n    film_release_year Int,\n    film_language LowCardinality(String),\n    film_length Int,\n    film_rating LowCardinality(String),\n    store_id Int,\n    store_address LowCardinality(String),\n    store_city LowCardinality(String),\n    store_postal_code LowCardinality(String),\n    store_country LowCardinality(String),\n    store_manager_id Int,\n    customer_id Int,\n    customer_since DateTime,\n    customer_city String\n)\nENGINE = ReplicatedMergeTree()\nORDER BY rental_id;"}'
        EOT
  }
}

resource "null_resource" "create_materialized_view" {
  depends_on = [aiven_service_integration.clickhouse_kafka_source, null_resource.create_analytics_table]

  provisioner "local-exec" {
    command = <<EOT
        curl '${local.api_url}/v1/project/${var.aiven_project_name}/service/${aiven_clickhouse.clickhouse.service_name}/clickhouse/query' \
            -H 'content-type: application/json' \
            -H 'authorization: aivenv1 ${var.aiven_api_token}' \
            --data-raw '{"database":"default","query":"CREATE MATERIALIZED VIEW materialised_view TO rental_analytics AS\nSELECT * FROM `service_data-pipeline-test-dvd-rental-kafka`.rental_raw;"}'
        EOT
  }
}
