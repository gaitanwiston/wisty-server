# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec first (cache friendly)
COPY pubspec.* ./

RUN dart pub get

# Copy all source code
COPY . .

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Build Dart Frog (optional, keeps frog build artifacts)
RUN dart_frog build

# Compile server to AOT executable
RUN dart compile exe ./bin/server.dart -o ./bin/server_exec

# ---------- Runtime Stage ----------
FROM debian:stable-slim

WORKDIR /app

# Install minimal dependencies (optional: ca-certificates for HTTPS)
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy compiled server executable
COPY --from=build /app/bin/server_exec ./bin/server_exec

# Only copy public if it exists
COPY --from=build /app/public/ ./public/ 2>/dev/null || true

# Expose port
EXPOSE 8080

# Run server
CMD ["./bin/server_exec"]