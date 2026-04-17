# Use rocker/shiny as base image
FROM rocker/shiny:4.4.3

# Install system dependencies (retry to tolerate transient apt mirror failures)
RUN for i in 1 2 3; do \
        apt-get update && apt-get install -y --no-install-recommends \
            libcurl4-openssl-dev \
            libssl-dev \
            libxml2-dev \
            libpng-dev \
            gdal-bin \
            libgdal-dev \
            curl \
            libudunits2-dev \
        && break || { echo "apt attempt $i failed, retrying in $((i*15))s"; sleep $((i*15)); }; \
    done \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /srv/shiny-server/app

# Copy renv infrastructure first for caching
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

# Install renv and restore packages from lock file
RUN R -e "renv::restore(prompt = FALSE)"

# Copy application files
COPY . .

# Set permissions
RUN chown -R shiny:shiny /srv/shiny-server/app

# Expose port
EXPOSE 8080

# Set environment variables
ENV PORT=8080
ENV SHINY_ENV=production

# Run the application
CMD ["R", "-e", "source('app/run.R')"]
