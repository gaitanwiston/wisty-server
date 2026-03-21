FROM dart:stable AS build
WORKDIR /app
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart_frog build
RUN dart compile exe bin/server.dart -o bin/server_exec

FROM debian:stable-slim
WORKDIR /app
COPY --from=build /app/bin/server_exec ./bin/server_exec
EXPOSE 8080
CMD ["./bin/server_exec"]