#!/usr/bin/env bash
# Reproduces the showMvnDepsTree --inverse OOM (mill#6823) using the
# coursier CLI directly. Both Mill and cs share the same Tree.recursivePrint
# code path, so the exponential reverse-tree expansion affects both.
#
# Usage:
#   ./repro-cs.sh              # run with cs on PATH
#   CS=/path/to/cs ./repro-cs.sh
#
# To cap the JVM heap when using the JVM-based cs launcher (not the native binary):
#   CS="java -Xmx1g -jar /path/to/coursier.jar" ./repro-cs.sh
#
# Note: the Homebrew/native cs binary manages its own heap and ignores
# _JAVA_OPTIONS / JAVA_OPTS. To constrain it, use the JVM-based launcher above.

set -euo pipefail
# Default to the JAR-based launcher in this directory so heap can be capped via -Xmx.
# The native `cs` binary ignores _JAVA_OPTIONS / JAVA_OPTS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS="${CS:-java -Xmx1g -jar "${SCRIPT_DIR}/coursier"}"

# High-level framework deps — each pulls in the low-level ones transitively.
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

# Low-level deps that are transitively used by all of the above.
# Declaring them explicitly makes them reverse-tree *roots with many dependees* —
# the trigger condition for exponential blowup in Tree.recursivePrint.
# (The path-local `ancestors` set only breaks exact cycles; it doesn't prevent
# the same node being re-expanded via different branches.)
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

echo "=== Forward tree (--tree) ==="
echo "Line count:"
$CS resolve --tree "${ALL_DEPS[@]}" 2>/dev/null | wc -l

echo ""
echo "=== Reverse tree (--reverse-tree) ==="
echo "This is the operation that OOMs. Running now..."
time $CS resolve --reverse-tree "${ALL_DEPS[@]}"
