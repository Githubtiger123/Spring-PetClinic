# 只做运行时镜像：jar 由 CI 的 build-app 作业产出，这里直接拷贝
# 需要换源时用 kaniko 的 --build-arg 覆盖，例如接入 Harbor 代理缓存后改成本地地址
ARG JRE_IMAGE=docker.m.daocloud.io/library/eclipse-temurin:17-jre

FROM ${JRE_IMAGE}
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
