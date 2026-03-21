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

# Build Dart Frog API into binary
RUN dart_frog build
RUN dart compile exe bin/server.dart -o bin/server_exec

# Compile Signals Server into binary
RUN dart compile exe servers/signals_server.dart -o signals_server

# =================== RUNTIME IMAGE ===================
FROM debian:stable-slim

WORKDIR /app

# Copy binaries
COPY --from=build /app/bin/server_exec ./bin/server_exec
COPY --from=build /app/servers/signals_server .

# Expose port
EXPOSE 8080

# =================== SWITCH LOGIC ===================
CMD ["sh", "-c", "if [ \"$SERVICE\" = \"signals\" ]; then .servers/signals_server; else ./bin/server_exec; fi"]