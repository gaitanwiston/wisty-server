# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

# Install Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Build Dart Frog server
RUN dart_frog build

# Compile executable
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM debian:buster-slim

WORKDIR /app

COPY --from=build /app/server /app/server

EXPOSE 8080

CMD ["./server"]