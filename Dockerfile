# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Install Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

COPY pubspec.* ./
RUN dart pub get

COPY . .

# Build Dart Frog server
RUN dart_frog build
RUN dart compile exe build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM debian:buster-slim

WORKDIR /app
COPY --from=build /app/server .

EXPOSE 8080
CMD ["./server"]