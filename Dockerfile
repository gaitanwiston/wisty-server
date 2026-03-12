# Stage 1: Build stage
FROM dart:stable AS build

WORKDIR /app

# Copy dependencies files
COPY pubspec.* ./
RUN dart pub get

# Copy all source files
COPY . .

# Activate dart_frog CLI
RUN dart pub global activate dart_frog_cli

# Build Dart Frog server
RUN dart_frog build

# Compile the generated server to executable
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# Stage 2: Runtime stage
FROM debian:buster-slim

WORKDIR /app

# Copy the executable from build stage
COPY --from=build /app/server /app/server

# Copy public assets if you have any
COPY --from=build /app/.dart_frog/build/public /app/public

EXPOSE 8080

# Run the server
CMD ["./server"]