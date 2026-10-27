# ---- build stage ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY ci/settings.xml /tmp/settings.xml
COPY . .
RUN mvn -B --no-transfer-progress -s /tmp/settings.xml \
      -DskipTests -Dcheckstyle.skip=true -Dspring-javaformat.skip=true \
      package

# ---- runtime stage ----
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
