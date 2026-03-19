# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Activate Dart Frog CLI (for HTTP API build)
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec and fetch dependencies (cache-friendly)
COPY pubspec.* ./
RUN dart pub get

# Copy source code
COPY . .

# ---------- Build HTTP API (optional) ----------
RUN dart_frog build

# ---------- Build standalone WebSocket signals server ----------
RUN dart compile exe bin/server.dart -o server

# ---------- Runtime stage ----------
FROM dart:stable AS runtime

WORKDIR /app

# Copy compiled signals server
COPY --from=build /app/signals_server ./

# Expose port for signals server
EXPOSE 8081

# Run signals server
CMD ["./signals_server"]