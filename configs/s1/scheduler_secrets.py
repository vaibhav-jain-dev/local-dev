import urllib.parse
from .settings import *
from pathlib import Path

secrets  = {
    "staging_postgres_DbHost": "{{staging_postgres_DbHost}}",
    "staging_postgres_DbUser": "{{staging_postgres_DbUser}}",
    "staging_postgres_DbPswd": "{{staging_postgres_DbPswd}}",
    "staging_awsAccessKeyId": "{{staging_awsS3AccessKeyId}}",
    "staging_awsSecretAccessKey": "{{staging_awsS3SecretAccessId}}",
    "staging_awsSqsAccessKeyId": "{{staging_awsSqsAccessKeyId}}",
    "staging_awsSqsSecretAccessKey": "{{staging_awsSqsSecretAccessId}}",
    "qa_postgres_DbHost": "{{qa_postgres_DbHost}}",
    "qa_postgres_DbUser": "{{qa_postgres_DbUser}}",
    "qa_postgres_DbPswd": "{{qa_postgres_DbPswd}}",
    "qa_awsAccessKeyId": "{{qa_awsS3AccessKeyId}}",
    "qa_awsSecretAccessKey": "{{qa_awsS3SecretAccessId}}",
    "qa_awsSqsAccessKeyId": "{{qa_awsSqsAccessKeyId}}",
    "qa_awsSqsSecretAccessKey": "{{qa_awsSqsSecretAccessId}}",
    "staging_c3_api_key": "WNttqPQBQ4Gkn8wkLub19TbxfDVDR1F38I^O3P&S1A!T5G+V0H",
    "staging_c3_secret_key": "NAIV27jrPjZv1iocTshjXUm0BBppwnl68I^O3P&S1A!T5G+V0H",
    "staging_c3_webhook_auth_key": "563aacd4384a40bf8fe507cb26888083",
    "ephemeral_postgres_DbHost": "{{ephemeral_postgres_DbHost}}",
    "ephemeral_postgres_DbUser": "{{ephemeral_postgres_DbUser}}",
    "ephemeral_postgres_DbPswd": "{{ephemeral_postgres_DbPswd}}",
    "ephemeral_awsAccessKeyId": "{{ephemeral_awsS3AccessKeyId}}",
    "ephemeral_awsSecretAccessKey": "{{ephemeral_awsS3SecretAccessId}}",
    "ephemeral_awsSqsAccessKeyId": "{{ephemeral_awsSqsAccessKeyId}}",
    "ephemeral_awsSqsSecretAccessKey": "{{ephemeral_awsSqsSecretAccessId}}",
    "stag_postgres_DbHost": "ohdev-postgres.db.orangehealth.dev",
    "stag_postgres_DbUser": "admin",
    "stag_postgres_DbPswd": "wWQfBQffHeMALuQJBu4q",
    "stag_awsAccessKeyId": "MASKED_AWS_KEY",
    "stag_awsSecretAccessKey": "MASKED_SECRET",
    "stag_awsSqsAccessKeyId": "MASKED_AWS_KEY",
    "stag_awsSqsSecretAccessKey": "MASKED_SECRET"
}

REST_FRAMEWORK = {
    'DEFAULT_THROTTLE_RATES': {
        'user': '100000/min'
    },
    'EXCEPTION_HANDLER':
        'common.v1.custom_throttle_handler.custom_exception_handler'
}

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = "ckavu-^@mr+l!lto#x=lzybrzpnm559qdp(abbct)&*2%(9kcn"
DEBUG = False
ALLOWED_HOSTS = ['*']
DJANGO_ENV = "dev"
REPO_BASE_URL = "https://s2-scheduler-api.orangehealth.dev"
BASE_DIR = Path(__file__).resolve().parent.parent

##########################################################################

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'HOST': secrets['stag_postgres_DbHost'],
        'NAME': 's2_scheduler',
        'USER': secrets['stag_postgres_DbUser'],
        'PASSWORD': secrets['stag_postgres_DbPswd'],
        'OPTIONS': {'sslmode': 'require'},
        'POOL_OPTIONS': {
            'POOL_SIZE': 25,
            'MAX_OVERFLOW': 20,
            'RECYCLE': 300,
            'PRE_PING': True,
        }
    },
    'read_replica': {
        'ENGINE': 'django.db.backends.postgresql',
        'HOST': secrets['stag_postgres_DbHost'],
        'NAME': 's2_scheduler',
        'USER': secrets['stag_postgres_DbUser'],
        'PASSWORD': secrets['stag_postgres_DbPswd'],
        'OPTIONS': {'sslmode': 'require'},
        'POOL_OPTIONS': {
            'POOL_SIZE': 25,
            'MAX_OVERFLOW': 20,
            'RECYCLE': 300,
            'PRE_PING': True,
        }
    }
}
##########################################################################

# Redis Cache
CACHES = {
    'default': {
        'BACKEND': "django_redis.cache.RedisCache",
        'LOCATION': "redis://redis:6379/16",
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient',
        }
    },
    'availability': {
        'BACKEND': "django_redis.cache.RedisCache",
        'LOCATION': "redis://redis:6379/161",
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient'
        }
    },
}

##########################################################################

# Sentry Config
sentry_sdk.init(
    dsn="",
    integrations=[
        DjangoIntegration(),
        RedisIntegration(),
        CeleryIntegration()],

    # If you wish to associate users to errors (assuming you are using
    # django.contrib.auth) you may enable sending PII data.
    send_default_pii=True
)

##########################################################################

# Celery config
CELERY['BROKER_TRANSPORT_OPTIONS']['region'] = "ap-south-1"
CELERY['BROKER_TRANSPORT_OPTIONS']['queue_name_prefix'] = 's2-scheduler-'
CELERY['TASK_DEFAULT_QUEUE'] = 'test-queue'
SQS_ACCESS_KEY = secrets['stag_awsSqsAccessKeyId']
SQS_SECRET_KEY = secrets['stag_awsSqsSecretAccessKey']
SQS_URL = "sqs.ap-south-1.amazonaws.com/267224240039/"
CELERY['BROKER_URL'] = "sqs://{access_key}:{secret_key}@{sqs_url}".format(
    access_key=SQS_ACCESS_KEY,
    secret_key=urllib.parse.quote_plus(SQS_SECRET_KEY),
    sqs_url=SQS_URL,
)
# # Celery config
CELERY['CELERY_RESULT_BACKEND'] = "redis://redis:6379/17"

##########################################################################

# Token Config
TOKEN_CONFIG = {
    'SECRET_KEY': "MASKED_SECRETdUc=",
    'ALGORITHM': "HS256"
}

##########################################################################

# Accounts Microservice creds
ACCOUNTS_SETTINGS['SECRET_KEY'] = "574yEI0ziT072fxV3B2V1GkV"
ACCOUNTS_SETTINGS['BASE_URL'] = "http://accounts-api/"

##########################################################################

# Health API Microservice creds
HEALTH_SETTINGS['SECRET_KEY'] = "V1y86Ec7jXizIS8gfYYuvPWs"
HEALTH_SETTINGS['BASE_URL'] = "http://health-api/"

##########################################################################

# S3Wrapper Microservice creds
S3WRAPPER_SETTINGS['SECRET_KEY'] = "5Lo24c4LJt0K7aBDkYI9SNud"
S3WRAPPER_SETTINGS['BASE_URL'] = "https://s2-files.orangehealth.dev"
S3WRAPPER_SETTINGS['BUCKET_LOCUS_DATA_FEED'] = "s2-locus-task-data"

##########################################################################

SERVICE_KEYS['SHLINK']['SERVICE_URL'] = "https://orn.ge/rest/v3/short-urls"
SERVICE_KEYS['SHLINK']['API_KEY'] = "abcd9"
FEEDBACK_FORM_URL = "https://s2-feedback.orangehealth.dev/task/"

##########################################################################

# Tookan Config for fleet management
TOOKAN_CONFIG = {
    'API_KEY': "MASKED_SECRET22d8723b541b03",
    'BASE_URL': "https://api.tookanapp.com",
    'SHARED_SECRET': "Mq2Pq03Xalpa9Bt4",
    'USER_ID': "752808"
}
TASK_FAILED_NOTIF_EMAIL_ID = "schedular-qa-communication@orangehealth.in"

##########################################################################

# OMS creds
OMS_SETTINGS['BASE_URL'] = "http://oms-api/"
##########################################################################

##########################################################################
PARTNERS_SETTINGS = {
    'BASE_URL': "http://partner-api"
}

# Password Encryptor Config
PASSWORD_ENCRYPTION_KEY = "A3tFpxW5IVuPnfRo6i7wz7XS"

##########################################################################

CORS_ORIGIN_WHITELIST = [
    "https://s2-scheduler.orangehealth.dev",
    "https://s2-web.orangehealth.dev",
    "https://s2-www.orangehealth.dev",
    "https://s2-web-order.orangehealth.dev",
    "https://s2-feedback.orangehealth.dev",
    "https://s2-partner-order.orangehealth.dev"
]

##########################################################################

SERVICE_KEYS['OMS']['SECRET_KEY'] = "v55ws2TAppCFaLmpa4Ray1IE"
SERVICE_KEYS['HEALTH']['SECRET_KEY'] = "V89Co10c4vdSuDa52q9LiQbp"
SERVICE_KEYS['RETOOL']['SECRET_KEY'] = "TFVJ2K8Py6vqaRBj8AeGUdkaSTHNzMME"
SERVICE_KEYS['FEEDBACK']['SECRET_KEY'] = "4XNUlMju95bM6Da365i1uJ44"
SERVICE_KEYS['GEOMARK']['SECRET_KEY'] = '1TyrCH2BISraqXsed3TqrETY'
SERVICE_KEYS['OMS']['API_KEY'] = "iasKTEcYuqv0JnNM06utdNH3"
SERVICE_KEYS['PARTNERS']['API_KEY'] = "eL4JwCKSjFNxXxZ2t5CuqJ86Rz"
SERVICE_KEYS['PARTNERS']['SECRET_KEY'] = "5I9WEAnN2BrWTl0kVpHIXbOU"
SERVICE_KEYS["OCC"] = {"SECRET_KEY": ""}
SERVICE_KEYS['OCC']['SECRET_KEY'] = 'occ-secret-key'

##########################################################################
HUB_DUMMY_PHONE_NUMBER = "8722190485"
##########################################################################
ROUTE_OPTIMIZATION_HUB_IDS = "[]"
FRACTION_SLOTS_TO_EXPOSE = "1"
##########################################################################
# Tookan Config for fleet management
GOOGLE_MAP_CONFIG = {
    'API_KEY': "AIzaSyBqARqXNmVrLnH0IIMd2KZkf6TZetrwY6o",
    'BASE_URL': "https://maps.googleapis.com/maps/api/distancematrix/json"
}

##########################################################################

VOICE_CONFIG = {
    'EMEDIC_CUSTOMER_BRIDGE_ENABLED': "N" == "Y",
    'EMEDIC_CUSTOMER_BRIDGE_PHONE_NUMBER': "+918069454196"
}
VOICE_CALLBACK_KEY = "abcd"

##########################################################################

LOCUS_CONFIG = {
    'USERNAME': "oh-sandbox",
    'PASSWORD': "2b4b47ee-1a30-4d4d-97ab-7e15a005cf6c",
    'CLIENT_ID': "oh-sandbox",
    'WHITELISTING_IPS': "[52.3.126.217,18.207.33.83, 52.206.229.200, 34.232.104.219, 18.208.31.125,18.206.43.52, 172.19.0.1, 27.7.29.27]",
    'MIN_TRANSACTION_TIME': '1200',
    'MIN_TRANSACTION_TIME_ECG': 2760,
}

LOCUS_WEBHOOK_CONFIG = {
    'USERNAME': "locus/oh-sandbox",
    'PASSWORD': "a534dfe0-cc7e-48ad-bd71-f8860ea63de0"
}

LOCUS_HUB_IDS = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106]"
LOCUS_ROSTER_CITIES = "[1,2,3,4,5,7,8]"
LOCUS_ORDER_ID_PREFIX = "S2"

##########################################################################

SLOT_BLOCK_ACCESS_KEY = "MASKED_SECRET"
SETUP_TIME = "0"
WRAPUP_TIME = "0"
COMMUTE_TIME = "900"

BATCH_FLOW_HUBS = '[4]'
BATCH_FLOW_SWITCHOVER_DATE = '2024-02-26'
FLASH_SECRET_KEY = '14d05ca6-2f29-471b-93c1-d8887bb0ab1f'
ORANGERS_HUBS = '[12,5]'

##########################################################################

AWS_SNS_SQS_REGION = 'ap-south-1'

SERVICE_CONTROLLER_CONFIG = {
    'accounts': {
        'url': 'http://accounts-api',
        'key': '574yEI0ziT072fxV3B2V1GkV',
        'key_header': 'api-key',
    },
    'geomark': {
        'url': 'http://geomark-api',
        'key': '1TyrCH2BISraqXsed3TqrETY',
        'key_header': 'api-key',
    },
    'oms': {
        'url': 'http://oms-api',
        'key': 'abcd',
        'key_header': 'token',
    },
    'reporting': {
        'url': 'http://report-rebranding-api',
        'key': '',
        'key_header': '',
    },
    's3': {
        'url': 'http://s3wrapper-api',
        'key': 'd832-8939-4987-a35f-4bf921f459dd',
        'key_header': 'api-key',
    },

}

CDS_SERVICE = {
    'BASE_URL': 'http://cds-api',
    'SERVICE': 'SCHEDULER',
    'API_KEY': '87a93ca31a9c4580b19f61dc2a731b90',
    'USER_EMAIL': 'scheduler-api@orangehealth.in'
}

OCC_SERVICE = {
    'BASE_URL': 'https://s2-occ-api.orangehealth.dev',
    'SERVICE': 'SCHEDULER',
    'API_KEY': 'todo',
    'USER_EMAIL': 'scheduler-api@orangehealth.in'
}

PUBSUB_REDIS_LOCATION = 'redis://redis:6379/32'
PUBSUB_REDIS_MAX_CONNECTIONS = 10
SERVER_DOMAIN = 's2'
EMEDIC_ATTENDANCE_CONFIG = {
    'PRE_ATTENDANCE_DISPLAY_TIME_IST': '12:00:00',
    'PRE_ATTENDANCE_DEADLINE_UTC': '14:30:00',
    'SHIFT_ATTENDANCE_DISPLAY_CUTTOFF_IN_MINUTES': '60',
    'SHIFT_ATTENDANCE_DEADLINE_IN_MINUTES': '30',
    'NAIL_DOC_UPLOAD_TOLERANCE_IN_HOURS': '48'
}

WAKEUP_CALL_CONFIG = '[21600,24300,27900,30600,34200,36900,40500,43200,55800,58500,62100,64800,68400,70500,74700,77400,24300,27900,30600,34200,36900,45300,47700,51300,54000]'

# ETS Microservice creds
EVENT_TRACKING_SETTINGS['SECRET_KEY'] = 'pd14HLj0FDrqJvdDj96P2JVc'
EVENT_TRACKING_SETTINGS['BASE_URL'] = 'http://ets-lab-api/api/v1/'

C3_API_CONFIG = {
    'api_key': secrets['staging_c3_api_key'],
    'secret_key': secrets['staging_c3_secret_key'],
    'webhook_auth_key': secrets['staging_c3_webhook_auth_key'],
    'emedic_id': '47',
}

ON_DEMAND_SETTINGS = {
    'SERVICEABLE_HUBS': '[5,12]',
    'AVAILABILITY_WINDOW_SIZE_IN_MINUTES': 30,
    'PADDING_ON_ETA_IN_MINUTES': 5,
    'MEDIC_LOCATION_CACHE_TIMEOUT_IN_SECONDS': 3*60,
    'DEDICATED_FLEETS': '[188]',
    'TRANSACTION_TIME_AT_PICKUP_IN_MINUTES': 8,
    'TRANSACTION_TIME_AT_DROP_IN_MINUTES': 3,
    'ETA_CUTOFF_FOR_CLINIC_IN_MINUTES': 30,
}

QUEUE_CONFIG['CONSUMER_QUEUE_NAME'] = 's2-scheduler-consumer'
QUEUE_CONFIG['TOPICS_TO_SUBSCRIBE'] = '["arn:aws:sns:ap-south-1:267224240039:s2-order-flow"]'
QUEUE_CONFIG['CONSUMER_QUEUE_URL'] = "https://sqs.ap-south-1.amazonaws.com/267224240039/s2-scheduler-consumer"

GOOGLE_OAUTH = {
    "CLIENT_ID": "45642087540-vr1cfovd8q9u6n66j90929lm978kh9c9.apps.googleusercontent.com",
    "PROJECT_ID": "oms-staging-49f5f",
    "AUTH_URI": "https://accounts.google.com/o/oauth2/auth",
    "TOKEN_URI": "https://oauth2.googleapis.com/token",
    "USER_INFO_URI": "https://www.googleapis.com/oauth2/v1/userinfo",
    "AUTH_PROVIDER_X509_CERT_URL": "https://www.googleapis.com/oauth2/v1/certs",
    "CLIENT_SECRET": "ELr5DApToSjYXVlmu7lfUOiv",
    "REDIRECT_URI": "https://s2-scheduler-api.orangehealth.dev/api/v1/oauth2callback",
    "SCOPES": ['https://www.googleapis.com/auth/userinfo.email', 'https://www.googleapis.com/auth/userinfo.profile'],
}

FRONTEND_URL = "https://s2-scheduler.orangehealth.dev/login"

OSRM_API_BASE_URL = 'https://staging-osrm.orangehealth.dev'
FIREBASE_DATABASE_URL = 'https://orangers-stag-3d017-default-rtdb.asia-southeast1.firebasedatabase.app'
FIREBASE_CREDENTIALS = BASE_DIR / "app/firebase_stag_credentials.json"
