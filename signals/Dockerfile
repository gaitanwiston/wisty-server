# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec first (cache friendly)
COPY pubspec.* ./

# Get dependencies
RUN dart pub get

# Copy only source code
COPY servers ./servers

# Compile executable
RUN dart compile exe servers/signals_server.dart -o bin/signals_server_exec

# ---------- Final Stage ----------
FROM debian:stable-slim

WORKDIR /app

# Copy executable
COPY --from=build /app/bin/signals_server_exec ./bin/signals_server_exec

# Set execute permissions
RUN chmod +x ./bin/signals_server_exec

# Expose port (Railway default)
EXPOSE 8080

# Run server
CMD ["./bin/signals_server_exec"]