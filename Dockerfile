# =================== BASE BUILD IMAGE ===================
FROM dart:stable AS build

WORKDIR /app

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec first (cache-friendly)
COPY pubspec.* ./

# Install dependencies
RUN dart pub get

# Copy all source code
COPY . .

# Build Dart Frog API (generates build/)
RUN dart_frog build

# Compile Signals Server
RUN dart compile exe servers/signals_server.dart -o signals_server

# =================== RUNTIME IMAGE ===================
FROM debian:stable-slim

WORKDIR /app

# Copy API build
COPY --from=build /app/build ./build

# Copy signals binary
COPY --from=build /app/signals_server .

# Expose port
EXPOSE 8080

# =================== SWITCH LOGIC ===================
CMD ["sh", "-c", "if [ \"$SERVICE\" = \"signals\" ]; then ./signals_server; else dart run build/bin/server.dart; fi"]