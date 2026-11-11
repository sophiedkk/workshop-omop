# One image for every R service of the workshop: the participant tutorial (learnr), the api (plumber),
# the facilitator app (Shiny), setup and data preparation. Each service picks its command in compose.yaml.
#
# The answer key is NOT in this image (.dockerignore excludes key.yml): it is mounted into the api only.
FROM docker.io/rocker/r-ver:4.6.2 AS base

# Binary packages from a dated Posit Package Manager snapshot, so rebuilds give the same versions.
ARG CRAN_SNAPSHOT=2026-11-01
RUN echo "options(repos = c(CRAN = 'https://p3m.dev/cran/__linux__/resolute/${CRAN_SNAPSHOT}'), timeout = 900)" \
        >> "${R_HOME}/etc/Rprofile.site"

# pandoc (R Markdown/learnr) from Ubuntu, and system libraries the binary R packages link against.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pandoc libcurl4t64 libssl3t64 libxml2-16 libfontconfig1 libfreetype6 \
        libharfbuzz0b libfribidi0 libpng16-16t64 libtiff6 libjpeg-turbo8 libsodium23 libuv1 \
 && rm -rf /var/lib/apt/lists/*

# Platform: tutorial, api, facilitator, setup.
RUN install2.r --error --skipinstalled --ncpus -1 \
        learnr rmarkdown shiny plumber RSQLite DBI yaml jsonlite httr2 openssl testthat \
 && rm -rf /tmp/downloaded_packages

# Workshop: OMOP packages (omock only for building the dataset).
RUN install2.r --error --skipinstalled --ncpus -1 \
        duckdb CDMConnector omock dplyr dbplyr ggplot2 clock PatientProfiles OmopSketch gt visOmopResults \
 && rm -rf /tmp/downloaded_packages

# rmarkdown must not try to re-render the tutorial at runtime (the image is read-only for the app user).
ENV RMARKDOWN_RUN_PRERENDER=0

FROM base AS app

# tini as PID 1: R does not handle SIGTERM, so without it every container takes 10 s to stop.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1001 workshop
WORKDIR /srv/workshop
COPY app/ app/
COPY branding/ branding/
COPY server/login-pages/ server/login-pages/
# Participant-safe workshop files only (no key.yml; see .dockerignore).
COPY workshops/ workshops/

# Prerender the tutorial(s) at build time so a participant's container starts in seconds.
# WS_RENDER_ONLY=1: the setup chunk does not connect to the data (there is none at build time).
RUN for d in workshops/*/; do \
        WS_RENDER_ONLY=1 Rscript -e "rmarkdown::render('${d}tutorial.Rmd', quiet = TRUE)" || exit 1; \
    done
# The files stay owned by root: participants' code (user workshop) can read them, not change them.

USER workshop
EXPOSE 3838
ENTRYPOINT ["/usr/bin/tini", "--"]
# Default: the participant tutorial (ShinyProxy starts one container per participant on port 3838).
CMD ["Rscript", "-e", "rmarkdown::run(Sys.getenv('WS_TUTORIAL', 'workshops/omop_explore/tutorial.Rmd'), shiny_args = list(host = '0.0.0.0', port = 3838, launch.browser = FALSE))"]
