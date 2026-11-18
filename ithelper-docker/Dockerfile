FROM php:8.1-fpm-alpine

# =============================================================================
# Image PHP-FPM untuk ITHelper (Laravel 8.83)
#
# Kenapa PHP 8.1 dan BUKAN 8.2 seperti AttendApp?
#   composer.lock ITHelper mengunci:
#     laravel/framework  v8.83.27  -> "php": "^7.3|^8.0"
#     doctrine/dbal      ^4.2     -> butuh PHP >= 8.1
#     nette/schema       v1.3.2   -> "8.1 - 8.4"
#   PHP 8.1 adalah versi tempat aplikasi ini dikembangkan (php -v lokal =
#   8.1.10), jadi paling kecil risiko regresinya. PHP 8.2 juga didukung lock
#   tersebut, tapi Laravel 8 di 8.2 memunculkan deprecation "dynamic property".
#   ITEM MONITORING BERBEDA: dia Laravel 10 -> memakai PHP 8.2 (lihat folder
#   imon-docker/Dockerfile).
#
# Yang TIDAK dipasang di sini dibanding app-laravel-docker:
#   - ekstensi `redis` + `pecl install redis`: aplikasi ini TIDAK memakai Redis
#     (CACHE_DRIVER=file, SESSION_DRIVER=file). Container Redis bersama tetap
#     dipakai AttendApp saja.
#   - nodejs/npm: aset front-end (adminlte, assets) sudah jadi di
#     `public/`, jadi tidak perlu build di server.
# =============================================================================

RUN apk add --no-cache \
    $PHPIZE_DEPS \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libzip-dev \
    libxml2-dev \
    oniguruma-dev \
    postgresql-client \
    postgresql-dev \
    zlib-dev \
    git \
    curl \
    unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        bcmath \
        exif \
        gd \
        intl \
        pdo_pgsql \
        pgsql \
        zip \
        opcache \
    && apk del $PHPIZE_DEPS

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# PHP-FPM pool (clear_env=no WAJIB, lihat komentar di file tersebut)
COPY php/www.conf /usr/local/etc/php-fpm.d/www.conf

# OPcache produksi (validate_timestamps=0 -> wajib recreate container tiap deploy)
COPY php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# Self-check konfigurasi efektif (dipanggil entrypoint setelah cache dibuat)
COPY php/selfcheck.php /usr/local/bin/app-selfcheck.php

# Entrypoint: permission, tunggu PostgreSQL, composer install, migrate, optimize
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Normalisasi line-ending (CRLF -> LF) agar script aman dijalankan di Linux
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm"]
