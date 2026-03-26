# Etapa 1 - Build
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

ARG SUPABASE_URL
ARG SUPABASE_ANON_KEY
RUN if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_ANON_KEY" ]; then \
      CLEAN_URL=$(echo "$SUPABASE_URL" | tr -d '`"'\''  ' | sed 's|^https\?://||' | sed 's|^|https://|'); \
      CLEAN_KEY=$(echo "$SUPABASE_ANON_KEY" | tr -d '`"'\'' '); \
      flutter build web --dart-define=SUPABASE_URL="$CLEAN_URL" --dart-define=SUPABASE_ANON_KEY="$CLEAN_KEY"; \
    else \
      flutter build web; \
    fi

# Etapa 2 - Servidor
FROM nginx:alpine

COPY --from=build /app/build/web /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
