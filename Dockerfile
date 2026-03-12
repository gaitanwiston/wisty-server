# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy project files
COPY pubspec.* ./
RUN dart pub get

COPY . .

# Build Dart Frog server inside container
RUN dart_frog build
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM debian:buster-slim

WORKDIR /app
COPY --from=build /app/server .

EXPOSE 8080
CMD ["./server"]