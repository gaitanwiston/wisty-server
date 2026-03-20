# ---------- Base Image ----------
FROM dart:stable

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

# Expose port
EXPOSE 8080

# Run server (NO AOT - stable)
CMD ["dart", "build/bin/server.dart"]