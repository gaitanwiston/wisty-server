# ---------- Build Stage ----------
FROM dart:stable AS build
WORKDIR /app

# Copy pubspec first (cache friendly)
COPY pubspec.* ./
RUN dart pub get

# Copy all source code
COPY . .

# Activate Dart Frog CLI
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

# Generate production build (hii ndiyo inayotengeneza routes ZOTE
# kiotomatiki kutoka 'routes/' folder - ikiwemo close.dart - ndani ya
# folda MPYA 'build/')
RUN dart_frog build

# 🚨🚨🚨 FIX YA BUG HALISI (chanzo cha "Route not found" kwa /close):
# AWALI hapa tulikuwa tukikusanya (compile) './bin/server.dart' - HII
# NI FAILI YA ASILI/CHANZO, SI ile iliyotengenezwa na 'dart_frog
# build' hapo juu! 'dart_frog build' inatengeneza faili MPYA KABISA
# ndani ya 'build/bin/server.dart' - hii NDIYO PEKEE yenye routes ZOTE
# (ikiwemo /close) zilizosajiliwa kiotomatiki kutoka 'routes/' folder.
# Kukusanya './bin/server.dart' (ya asili) kunapuuza KABISA matokeo ya
# 'dart_frog build' - server ya mwisho haikuwa "ikijua" kuhusu route
# yoyote iliyoongezwa/kubadilishwa baada ya faili hilo la awali
# kuandikwa. Imethibitishwa kutoka nyaraka rasmi za Dart Frog
# (dart-frog.dev/advanced/custom-dockerfile) - njia SAHIHI ni
# 'dart compile exe build/bin/server.dart'.
RUN dart pub get --offline
RUN dart compile exe build/bin/server.dart -o build/bin/server_exec


# ---------- Runtime Stage ----------
FROM debian:stable-slim
WORKDIR /app

# Install minimal dependencies (ca-certificates for HTTPS - muhimu
# kwa muunganiko na Deriv API, angalia fix ya awali ya Server 1)
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy compiled server executable - FIX: kutoka 'build/bin/', si
# './bin/' ya asili.
COPY --from=build /app/build/bin/server_exec ./bin/server_exec

# Optional: copy public folder **only if it exists in source**
# Kama unayo folda ya 'public/' (static files), inapaswa kutoka
# 'build/public/' pia (dart_frog build inanakili hiyo kule pia), si
# 'public/' ya asili.
# COPY --from=build /app/build/public ./public

# Expose port
EXPOSE 8080

# Run server
CMD ["./bin/server_exec"]
