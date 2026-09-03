# syntax=docker/dockerfile:1

FROM ghcr.io/cirruslabs/flutter:3.24.5 AS build
WORKDIR /app
COPY pubspec.yaml ./
COPY lib ./lib
COPY web ./web
COPY analysis_options.yaml ./
COPY .env ./
RUN flutter pub get && flutter build web --release --pwa-strategy=offline-first

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80
