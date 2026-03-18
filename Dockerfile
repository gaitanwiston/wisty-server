# ---------- Build stage ----------
FROM dart:stable AS build

WORKDIR /app

# Install Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy pubspec and get dependencies
COPY pubspec.* ./
RUN dart pub get

# Copy the rest of the source code
COPY . .

# Build Dart Frog server
RUN dart_frog build

# Compile the server to native executable (AOT)
RUN dart compile exe build/bin/server.dart -o server

# ---------- Runtime stage ----------
FROM dart:stable AS runtime

WORKDIR /app

# Copy the compiled server from build stage
COPY --from=build /app/server ./

# Copy any other required assets (optional)
# COPY --from=build /app/build ./

# Expose the port
EXPOSE 8080

# Run the server
CMD ["./server"]