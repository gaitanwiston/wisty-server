# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec files first (cache-friendly)
COPY pubspec.* ./

# Get dependencies
RUN dart pub get

# Copy all source code
COPY . .

# Build Dart Frog HTTP API (generates build/ folder)
RUN dart_frog build

# ---------- Runtime Stage ----------
FROM dart:stable AS runtime

WORKDIR /app

# Copy build output for Dart Frog API
COPY --from=build /app/build ./build

# Copy server entrypoint
COPY --from=build /app/bin/server.dart ./bin/server.dart

# Expose ports
EXPOSE 8080

# Run Dart Frog server
CMD ["dart", "run", "bin/server.dart"]