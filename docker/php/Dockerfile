FROM composer:2 AS vendor

WORKDIR /app
COPY composer.json composer.lock symfony.lock ./
RUN composer install --no-autoloader --no-interaction --no-scripts \
  --ignore-platform-req=ext-gd \
  --ignore-platform-req=ext-intl \
  --ignore-platform-req=ext-ldap


FROM node:20-alpine AS frontend

WORKDIR /app
COPY package.json yarn.lock .yarnrc.yml ./
COPY core/app/core/package.json core/app/core/
COPY core/yarn/ core/yarn/
COPY core/angular/ core/angular/
RUN corepack enable && yarn install --immutable
RUN corepack enable && yarn merge-angular-json
COPY . .
RUN corepack enable && yarn build-dev


FROM php:8.2-fpm-alpine

RUN apk add --no-cache \
    bash \
    curl \
    mysql-client \
    nginx \
    openssl \
    unzip \
    git \
    $PHPIZE_DEPS \
    openldap-dev \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libwebp-dev \
    libxpm-dev \
    icu-dev \
    libzip-dev \
    oniguruma-dev \
  && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-xpm \
  && docker-php-ext-install -j$(nproc) \
    pdo_mysql \
    mysqli \
    ldap \
    gd \
    intl \
    zip \
    bcmath \
    opcache \
  && pecl install redis && docker-php-ext-enable redis \
  && docker-php-ext-enable ldap \
  && rm -rf /tmp/pear

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

COPY docker/php/php.ini $PHP_INI_DIR/conf.d/99-suitecrm.ini
COPY docker/php/php.dev.ini $PHP_INI_DIR/conf.d/100-suitecrm-dev.ini
RUN echo "clear_env = no" >> /usr/local/etc/php-fpm.d/zz-docker.conf

COPY --from=vendor /app/vendor ./vendor
COPY --from=frontend /app/public/dist ./public/dist

COPY . .

RUN composer require scssphp/scssphp "^1.5" --no-interaction --no-plugins --no-scripts 2>/dev/null && \
    /var/www/html/vendor/bin/pscss -s compressed public/legacy/themes/suite8/css/Dawn/style.scss > public/legacy/themes/suite8/css/Dawn/style.css && \
    composer remove scssphp/scssphp --no-interaction --no-plugins --no-scripts 2>/dev/null || true

COPY docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

COPY docker/scripts/ /usr/local/bin/

COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

RUN composer dump-autoload --optimize 2>/dev/null || true

RUN chmod +x bin/console

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
  /usr/local/bin/cron.sh \
  /usr/local/bin/worker.sh \
  /usr/local/bin/healthcheck.sh \
  /usr/local/bin/setup-env.sh \
  && mkdir -p \
    /var/www/html/cache \
    /var/www/html/logs \
    /var/www/html/tmp \
    /var/www/html/public/legacy/upload \
    /var/www/html/public/legacy/custom \
    /var/www/html/public/media \
    /var/www/html/extensions \
    /var/www/html/config \
  && ln -sf ../../vendor /var/www/html/public/legacy/vendor \
  && chown -R www-data:www-data /var/www/html

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
