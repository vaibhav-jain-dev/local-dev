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

# GitHub token for private repo access (classic PAT with repo scope)
ARG PYTHON_CORE_UTILS_TOKEN2

# Add python-core-utils from Orange Health private GitHub repo
ARG PYTHON_CORE_UTILS_VERSION=v1.1.1#egg=python-core-utils
RUN sed -i -e '$a\\' /requirements/common.txt \
    && echo "git+https://x-access-token:${PYTHON_CORE_UTILS_TOKEN2}@github.com/Orange-Health/python-core-utils.git@${PYTHON_CORE_UTILS_VERSION}" >> /requirements/common.txt

# Remove conflicting packages from dev.txt before installing
RUN grep -v -E "^PyYAML==|^wrapt==" /requirements/dev.txt > /requirements/dev_fixed.txt && \
    pip install -r /requirements/dev_fixed.txt

# Install error_framework from Orange Health private GitHub repo
# Using x-access-token format (token as password) for GitHub PAT authentication
RUN git config --global credential.helper '' && \
    if [ -n "$PYTHON_CORE_UTILS_TOKEN2" ]; then \
        pip install git+https://x-access-token:${PYTHON_CORE_UTILS_TOKEN2}@github.com/Orange-Health/error-framework.git@master || \
        pip install git+https://x-access-token:${PYTHON_CORE_UTILS_TOKEN2}@github.com/Orange-Health/error_framework.git@master; \
    else \
        echo "Warning: PYTHON_CORE_UTILS_TOKEN2 not set - error_framework not installed"; \
    fi

RUN mkdir /app
WORKDIR /app
COPY ./app /app
COPY ./serviceAccountKey.json /serviceAccountKey.json

CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
