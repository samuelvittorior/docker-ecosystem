FROM php:8.2-fpm-alpine

# Install system dependencies
RUN apk add --no-cache \
    $PHPIZE_DEPS \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libzip-dev \
    libxml2-dev \
    oniguruma-dev \
    postgresql-dev \
    zlib-dev \
    git \
    curl \
    unzip \
    npm \
    nodejs \
    && docker-php-ext-install -j$(nproc) \
        bcmath \
        gd \
        intl \
        pdo_pgsql \
        pgsql \
        zip \
        opcache \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del $PHPIZE_DEPS

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Copy custom PHP-FPM pool config
COPY php/www.conf /usr/local/etc/php-fpm.d/www.conf

# Copy OPcache config
COPY php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# Entrypoint: composer install, storage link, migrate (opsional)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Normalisasi line-ending (CRLF -> LF) agar script aman dijalankan di Linux
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

# Set working directory
WORKDIR /var/www/html

# Expose PHP-FPM port
EXPOSE 9000

# Default command
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm"]