#!/usr/bin/env bash
# Run the reverse-tree OOM repro with a specific coursier version.
#
# Usage:
#   ./repro-with-version.sh <version>     e.g. 2.1.24 or 2.1.25-M25
#
# Downloads coursier-<version>.jar if not already cached in .coursier-jars/,
# then runs the reverse-tree repro with -Xmx1g.
#
# Exit codes:
#   0  completed without OOM (regression check: not affected)
#   1  OOM or other failure  (bug present)

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <coursier-version>" >&2
  exit 2
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR_DIR="${SCRIPT_DIR}/.coursier-jars"
JAR="${JAR_DIR}/coursier-${VERSION}.jar"

mkdir -p "${JAR_DIR}"

if [[ ! -f "${JAR}" ]]; then
  URL="https://github.com/coursier/coursier/releases/download/v${VERSION}/coursier.jar"
  echo "Downloading coursier ${VERSION} from ${URL} ..."
  curl -fL --progress-bar -o "${JAR}" "${URL}"
fi

GC_LOG="${SCRIPT_DIR}/gc-${VERSION}.log"
# GCTimeLimit=40: OOM if >40% of CPU time is spent in GC (default 98).
# This triggers GCOverheadLimitExceeded well before heap is fully exhausted,
# giving the GC log time to record the pressure leading up to failure.
# -Xlog:gc (no wildcard) avoids shell glob expansion of gc*.
CS=(java -Xmx1g -XX:+ExitOnOutOfMemoryError
  -Xlog:gc:file="${GC_LOG}":time,uptime
  -XX:GCTimeLimit=40
  -jar "${JAR}")

FRAMEWORK_DEPS=(
  "com.vaadin:vaadin:24.6.6"
  "com.vaadin:vaadin-spring-boot-starter:24.6.6"
  "org.springframework.boot:spring-boot-starter-web:3.4.5"
  "org.springframework.boot:spring-boot-starter-data-jpa:3.4.5"
  "org.springframework.boot:spring-boot-starter-security:3.4.5"
  "org.springframework.boot:spring-boot-starter-actuator:3.4.5"
  "org.springframework.boot:spring-boot-starter-oauth2-client:3.4.5"
  "org.springframework.cloud:spring-cloud-starter-openfeign:4.2.1"
  "org.springframework.cloud:spring-cloud-starter-netflix-eureka-client:4.2.1"
  "org.springframework.cloud:spring-cloud-starter-gateway:4.2.1"
  "org.springframework.kafka:spring-kafka:3.3.5"
  "org.apache.spark:spark-sql_2.13:4.1.1"
  "org.apache.spark:spark-mllib_2.13:4.1.1"
  "org.apache.spark:spark-streaming_2.13:4.1.1"
  "org.apache.spark:spark-graphx_2.13:4.1.1"
  "org.apache.hadoop:hadoop-client:3.4.1"
  "org.apache.flink:flink-streaming-java:1.20.1"
  "org.hibernate.orm:hibernate-core:6.6.13.Final"
)

LOW_LEVEL_DEPS=(
  "org.slf4j:slf4j-api:2.0.17"
  "org.slf4j:slf4j-simple:2.0.17"
  "com.fasterxml.jackson.core:jackson-core:2.18.3"
  "com.fasterxml.jackson.core:jackson-databind:2.18.3"
  "com.fasterxml.jackson.core:jackson-annotations:2.18.3"
  "com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.18.3"
  "com.fasterxml.jackson.module:jackson-module-scala_2.13:2.18.3"
  "com.google.guava:guava:33.4.8-jre"
  "commons-io:commons-io:2.19.0"
  "org.apache.commons:commons-lang3:3.17.0"
  "org.apache.commons:commons-collections4:4.5.0"
  "io.netty:netty-all:4.1.121.Final"
  "io.netty:netty-buffer:4.1.121.Final"
  "io.netty:netty-codec:4.1.121.Final"
  "io.netty:netty-handler:4.1.121.Final"
  "io.netty:netty-transport:4.1.121.Final"
  "org.springframework:spring-core:6.2.7"
  "org.springframework:spring-beans:6.2.7"
  "org.springframework:spring-context:6.2.7"
  "org.springframework:spring-web:6.2.7"
  "org.springframework:spring-webmvc:6.2.7"
  "org.springframework:spring-tx:6.2.7"
  "org.springframework:spring-aop:6.2.7"
  "io.micrometer:micrometer-core:1.14.6"
  "io.micrometer:micrometer-registry-prometheus:1.14.6"
  "org.apache.httpcomponents.client5:httpclient5:5.4.4"
  "org.apache.zookeeper:zookeeper:3.9.3"
  "com.google.protobuf:protobuf-java:4.30.2"
)

ALL_DEPS=("${FRAMEWORK_DEPS[@]}" "${LOW_LEVEL_DEPS[@]}")

echo ""
echo "=== coursier ${VERSION}: reverse tree (--reverse-tree) ==="
if "${CS[@]}" resolve --reverse-tree "${ALL_DEPS[@]}" > /dev/null 2>&1; then
  echo "PASS: completed without OOM"
  exit 0
else
  echo "FAIL: OOM or error (exit $?)"
  exit 1
fi
