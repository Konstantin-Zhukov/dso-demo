# Stage 1 - Build
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests

# Stage 2 - Run
FROM amazoncorretto:17-alpine
ARG USER=devops
ENV HOME=/home/$USER
WORKDIR /app

RUN adduser -D $USER && \
    chown $USER:$USER /app

COPY --from=build /app/target/demo-0.0.1-SNAPSHOT.jar app.jar

USER $USER

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -q --spider http://localhost:8080/actuator/health || exit 1

CMD ["java", "-jar", "app.jar"]
