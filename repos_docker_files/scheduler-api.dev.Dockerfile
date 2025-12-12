FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV PYTHONPATH "${PYTHONPATH}:/app"
ENV DJANGO_SETTINGS_MODULE=app.secrets

RUN  apt-get update && \
  apt-get install -y --no-install-recommends \
  procps \
  awscli \
  jq \
  postgresql-client \
  mime-support \
  libpcre3 \
  build-essential \
  libpcre3-dev \
  libpq-dev \
  gcc \
  libcurl4-openssl-dev \
  libssl-dev \
  git && \
  rm -rf /var/lib/apt/lists/*

# GitHub token for private repo access (classic PAT with repo scope)
ARG PYTHON_CORE_UTILS_TOKEN
ARG PYTHON_CORE_UTILS_VERSION=v1.1.1#egg=python-core-utils
COPY ./requirements /requirements

RUN sed -i -e '$a\\' /requirements/common.txt \
    && echo "git+https://${PYTHON_CORE_UTILS_TOKEN}:x-oauth-basic@github.com/Orange-Health/python-core-utils.git@${PYTHON_CORE_UTILS_VERSION}" >> /requirements/common.txt

# Remove conflicting packages from dev.txt before installing
RUN grep -v -E "^PyYAML==|^wrapt==" /requirements/dev.txt > /requirements/dev_fixed.txt && \
    pip install -r /requirements/dev_fixed.txt

RUN pip install --upgrade pip setuptools wheel && \
  pip install --no-cache-dir -r /requirements/dev_fixed.txt
  
RUN mkdir /app
WORKDIR /app
COPY ./app /app

# Install debugpy for remote debugging
RUN pip install debugpy

# Expose debug port
EXPOSE 5678

# Run with debugpy enabled (without --wait-for-client for faster startup)
# Debugger will be available on port 5678, attach when needed
# Hot reload is enabled by default (removed --noreload flag)
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "manage.py", "runserver", "0.0.0.0:8010"]
