# ---------- Base Image ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec first (cache friendly)
COPY pubspec.* ./

RUN dart pub get

# Copy source code
COPY . .

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Build Dart Frog
RUN dart_frog build

# Compile server
RUN dart compile exe ./bin/server.dart -o ./bin/server_exec

# ---------- Runtime Image ----------
FROM debian:stable-slim

WORKDIR /app

# Copy compiled executable and build artifacts
COPY --from=build /app/bin/server_exec ./bin/server_exec
COPY --from=build /app/bin/frog_tool/ ./bin/frog_tool/
COPY --from=build /app/public/ ./public/

# Expose port
EXPOSE 8080

# Run server
CMD ["./bin/server_exec"]