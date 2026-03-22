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

# Install minimal dependencies (optional: if you need curl, ca-certificates, etc.)
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy compiled server executable and frog tool
COPY --from=build /app/bin/server_exec ./bin/server_exec
COPY --from=build /app/bin/frog_tool/ ./bin/frog_tool/

# Only copy public if it exists
# (avoid error if folder is missing)
COPY --from=build /app/public/ ./public/ 2>/dev/null || true

# Expose port
EXPOSE 8080

# Run server
CMD ["./bin/server_exec"]