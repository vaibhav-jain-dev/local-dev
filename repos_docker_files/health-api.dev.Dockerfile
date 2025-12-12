FROM python:3.8.3-slim-buster

ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV PYTHONPATH "${PYTHONPATH}:/app"
ENV DJANGO_SETTINGS_MODULE=app.secrets

RUN sed -i 's|http://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list && \
    sed -i '/security.debian.org/d' /etc/apt/sources.list && \
    apt-get update -y && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    libpcre3 \
    mime-support \
    postgresql-client \
    libpq-dev \
    gcc \
    libcurl4-openssl-dev \
    libssl-dev \
    build-essential \
    libpcre3-dev \
    python3-dev \
    s4cmd \
    git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY ./requirements /requirements

# Remove conflicting packages from dev.txt before installing
RUN grep -v -E "^PyYAML==|^wrapt==" /requirements/dev.txt > /requirements/dev_fixed.txt

# Install dependencies with cache mount for faster builds
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r /requirements/dev_fixed.txt

# Add python-core-utils from Orange Health private GitHub repo
ARG PYTHON_CORE_UTILS_VERSION=v1.1.1#egg=python-core-utils
ARG PYTHON_CORE_UTILS_TOKEN
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install git+https://x-access-token:${PYTHON_CORE_UTILS_TOKEN}@github.com/Orange-Health/python-core-utils.git@${PYTHON_CORE_UTILS_VERSION}

# Install debugpy for remote debugging (before copying app for better caching)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install debugpy

RUN mkdir /app
WORKDIR /app
COPY ./app /app
COPY ./serviceAccountKey.json /serviceAccountKey.json

# Expose debug port
EXPOSE 5678

# Run with debugpy enabled (without --wait-for-client for faster startup)
# Debugger will be available on port 5678, attach when needed
# Hot reload is enabled by default (removed --noreload flag)
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "manage.py", "runserver", "0.0.0.0:8000"]
