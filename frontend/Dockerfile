# syntax=docker/dockerfile:1

# Flutter web client behind nginx (see nginx.conf for the API proxy).
# pubspec.lock needs Dart >= 3.10, so the old 3.24.5 image could no longer
# resolve dependencies. Pin FLUTTER_IMAGE to your local `flutter --version`
# for reproducible builds.
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:stable
FROM ${FLUTTER_IMAGE} AS build
WORKDIR /app
# Dependencies first (cached layer). The local webview plugin is a path
# dependency, so it has to be in the context before `pub get`.
COPY pubspec.yaml pubspec.lock ./
COPY plugins ./plugins
RUN flutter pub get
COPY analysis_options.yaml ./
COPY lib ./lib
COPY web ./web
# Offline-first service worker is the default strategy.
RUN flutter build web --release

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80
