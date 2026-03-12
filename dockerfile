# Stage 1: Build
FROM dart:stable AS build
WORKDIR /app

# Copy dependency files
COPY pubspec.* ./
RUN dart pub get

# Copy full project
COPY . .

# Compile Dart Frog server to executable
RUN dart compile exe bin/server.dart -o bin/server_exe

# Stage 2: Runtime
FROM debian:buster-slim
WORKDIR /app

# Copy compiled executable and routes
COPY --from=build /app/bin/server_exe ./bin/server_exe
COPY --from=build /app/routes ./routes
COPY --from=build /app/pubspec.* ./

# Set Railway env variables
ENV PORT=8080
ENV HOST=0.0.0.0

EXPOSE 8080

# Run server
CMD ["bin/server_exe"]