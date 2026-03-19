# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec and fetch dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy source code
COPY . .

# Optional: build Dart Frog project (cache AOT)
RUN dart_frog build

# ---------- Runtime stage ----------
FROM dart:stable AS runtime

WORKDIR /app

# Copy entire app from build stage
COPY --from=build /app ./

# Expose port for HTTP + WebSocket server
EXPOSE 8080

# Run Dart Frog server (HTTP + /signals WebSocket)
CMD ["dart", "run", "bin/server.dart"]