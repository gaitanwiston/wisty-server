# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec and fetch dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy all source code
COPY . .

# Build Dart Frog server
RUN dart pub global activate dart_frog_cli
RUN dart_frog build

# Compile the generated server to executable
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM debian:buster-slim

WORKDIR /app

# Copy the compiled server from build stage
COPY --from=build /app/server .

# Set permissions
RUN chmod +x server

# Expose port
EXPOSE 8080

# Run server
CMD ["./server"]