# ---------- Build stage ----------
FROM dart:stable AS build

# Set workdir
WORKDIR /app

# Copy pubspec files and get dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy the full source code
COPY . .

# Activate Dart Frog CLI and build the server
RUN dart pub global activate dart_frog_cli
RUN dart_frog build

# Compile the generated server to an executable
RUN dart compile exe .dart_frog/build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM debian:buster-slim

WORKDIR /app

# Copy compiled executable from build stage
COPY --from=build /app/server /app/server

# Copy necessary assets (if any)
COPY --from=build /app/.dart_frog/build/public /app/public

# Expose port
EXPOSE 8080

# Run the server
CMD ["./server"]