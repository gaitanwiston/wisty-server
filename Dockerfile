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

# Build Dart Frog server
RUN dart_frog build

# Compile server to native executable (AOT)
RUN dart compile exe bin/server.dart -o server

# ---------- Runtime stage ----------
FROM dart:stable AS runtime

WORKDIR /app

# Copy compiled server
COPY --from=build /app/server ./

# Expose port
EXPOSE 8080

# Run server
CMD ["./server"]