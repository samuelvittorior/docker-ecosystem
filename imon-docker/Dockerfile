FROM php:8.2-fpm-alpine

# =============================================================================
# Image PHP-FPM untuk ItemMonitoring (Laravel 10.50)
#
# Kenapa PHP 8.2 (beda dengan ITHelper yang 8.1)?
#   composer.lock ItemMonitoring: laravel/framework v10.50.2 -> "php": "^8.1"
#   Laravel 10 didukung penuh di PHP 8.1-8.3, dan 8.2 adalah pilihan seimbang
#   (masih menerima perbaikan keamanan, tanpa deprecation yang mengganggu).
#   Aturan umum: SATU VERSI PHP PER APLIKASI sesuai composer.lock-nya.
#
# Aplikasi ini SUDAH dikonfigurasi memakai PostgreSQL (DB_CONNECTION=pgsql)
# walaupun fiturnya belum memakai database. Ekstensi pgsql tetap dipasang
# supaya migrasi & koneksi siap pakai tanpa build ulang image.
#
# Yang TIDAK dipasang:
#   - ekstensi `redis`: aplikasi ini tidak memakai Redis (cache & session = file)
#   - nodejs/npm: aset front-end (public/*.html, public/js) sudah jadi
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
