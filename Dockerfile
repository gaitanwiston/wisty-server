# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec first (cache-friendly)
COPY pubspec.* ./

# Get dependencies
RUN dart pub get

# Copy all source code
COPY . .

# Build Dart Frog API (generates build/)
RUN dart_frog build

# Compile server to a self-contained executable
RUN dart compile exe bin/server.dart -o bin/server_exec

# ---------- Runtime Stage ----------
FROM gcr.io/distroless/cc-debian11 AS runtime
WORKDIR /app

# Copy the compiled executable from build stage
COPY --from=build /app/bin/server_exec ./server_exec

# Copy build folder (needed by Dart Frog for routes)
COPY --from=build /app/build ./build

# Expose Dart Frog port
EXPOSE 8080

# Run server executable
CMD ["./server_exec"]