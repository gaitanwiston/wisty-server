# ---------------- Stage 1: Build Stage ----------------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec files and fetch dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy the rest of the project
COPY . .

# Install Dart Frog CLI
RUN dart pub global activate dart_frog_cli

# Add Dart Frog bin to PATH
ENV PATH="$PATH:/root/.pub-cache/bin"

# Build Dart Frog server (this generates .dart_frog/build/bin/server.dart)
RUN dart_frog build

# Compile the generated server to executable
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# ---------------- Stage 2: Runtime Stage ----------------
FROM debian:buster-slim

WORKDIR /app

# Copy the compiled server executable from build stage
COPY --from=build /app/server /app/server

# Copy public assets if any (optional)
COPY --from=build /app/.dart_frog/build/public /app/public

# Expose port
EXPOSE 8080

# Start the server
CMD ["./server"]