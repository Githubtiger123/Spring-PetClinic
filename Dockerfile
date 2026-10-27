# 基础镜像走国内源（Pod 内无法访问 index.docker.io）
# 需要换源时用 kaniko 的 --build-arg 覆盖，例如接入 Harbor 代理缓存后改成本地地址
ARG MAVEN_IMAGE=docker.m.daocloud.io/library/maven:3.9-eclipse-temurin-17
ARG JRE_IMAGE=docker.m.daocloud.io/library/eclipse-temurin:17-jre

# ---- build stage ----
FROM ${MAVEN_IMAGE} AS build
WORKDIR /app
COPY ci/settings.xml /tmp/settings.xml
COPY . .
RUN mvn -B --no-transfer-progress -s /tmp/settings.xml \
      -DskipTests -Dcheckstyle.skip=true -Dspring-javaformat.skip=true \
      package

# ---- runtime stage ----
FROM ${JRE_IMAGE}
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
