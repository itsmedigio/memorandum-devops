# ---- Build stage ----
FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /app
COPY VaultDemo.java .
RUN javac VaultDemo.java

# ---- Runtime stage ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Create the directory where Vault Agent will write secrets (shared volume mount point)
RUN mkdir -p /vault/secrets

COPY --from=build /app/VaultDemo.class .

# Run as non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

ENTRYPOINT ["java", "VaultDemo"]