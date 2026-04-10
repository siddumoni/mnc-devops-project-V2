# Multi-stage build — builder stage compiles, runtime stage runs only the JAR.
# Final image: ~200MB. Without multi-stage it would be ~600MB with Maven included.

# ── Stage 1: Build ────────────────────────────────────────────────────────
FROM maven:3.9-amazoncorretto-17 AS builder
WORKDIR /app
# Cache dependency layer separately — only invalidated when pom.xml changes
COPY pom.xml .
RUN mvn dependency:resolve --batch-mode --no-transfer-progress -q
COPY src ./src
RUN mvn clean package -DskipTests --batch-mode --no-transfer-progress -q

# ── Stage 2: Runtime ─────────────────────────────────────────────────────
FROM amazoncorretto:17-alpine3.18
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser

ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.title="mnc-app-backend"

EXPOSE 8080
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-XX:+ExitOnOutOfMemoryError", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
