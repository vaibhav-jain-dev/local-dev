import urllib.parse
from .settings import *

SERVER_DOMAIN = 's2'

secrets = {
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
    
    "stag_postgres_DbHost": "ohdev-postgres.db.orangehealth.dev",
    "stag_postgres_DbUser": "admin",
    "stag_postgres_DbPswd": "wWQfBQffHeMALuQJBu4q",
    "stag_awsAccessKeyId": "MASKED_AWS_KEY",
    "stag_awsSecretAccessKey": "MASKED_SECRET",
    "stag_awsSqsAccessKeyId": "MASKED_AWS_KEY",
    "stag_awsSqsSecretAccessKey": "MASKED_SECRET",
    
    "ephemeral_postgres_DbHost": "{{ephemeral_postgres_DbHost}}",
    "ephemeral_postgres_DbUser": "{{ephemeral_postgres_DbUser}}",
    "ephemeral_postgres_DbPswd": "{{ephemeral_postgres_DbPswd}}",
    "ephemeral_awsAccessKeyId": "{{ephemeral_awsS3AccessKeyId}}",
    "ephemeral_awsSecretAccessKey": "{{ephemeral_awsS3SecretAccessId}}",
    "ephemeral_awsSqsAccessKeyId": "{{ephemeral_awsSqsAccessKeyId}}",
    "ephemeral_awsSqsSecretAccessKey": "{{ephemeral_awsSqsSecretAccessId}}"
}
# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = '4mtykj0Zwfuc0S37j19SNaDXwDuuJRqK'
ALLOWED_HOSTS = ['*']
DEBUG = True
DJANGO_ENV = 's1'
##########################################################################
# Database
# https://docs.djangoproject.com/en/3.0/ref/settings/#databases
DATABASES = {
    'default': {
        'ENGINE': 'dj_db_conn_pool.backends.postgresql',
        'HOST': secrets["stag_postgres_DbHost"],
        'NAME': 's1_healthapi',
        'USER': secrets["stag_postgres_DbUser"],
        'PASSWORD': secrets["stag_postgres_DbPswd"],
        'CONN_MAX_AGE': 0,
        'OPTIONS': {'sslmode': 'require'},
        'POOL_OPTIONS': {
            'POOL_SIZE': 3,
            'MAX_OVERFLOW': 2,
            'RECYCLE': 300,
            'PRE_PING': True,
            'POOL_TIMEOUT': 3,
            'POOL_RESET_ON_RETURN': 'rollback',
        }
    },
    'master': {
        'ENGINE': 'dj_db_conn_pool.backends.postgresql',
        'HOST': secrets["stag_postgres_DbHost"],
        'NAME': 's1_healthapi',
        'USER': secrets["stag_postgres_DbUser"],
        'PASSWORD': secrets["stag_postgres_DbPswd"],
        'CONN_MAX_AGE': 0,
        'OPTIONS': {'sslmode': 'require'},
        'POOL_OPTIONS': {
            'POOL_SIZE': 3,
            'MAX_OVERFLOW': 2,
            'RECYCLE': 300,
            'PRE_PING': True,
            'POOL_TIMEOUT': 3,
            'POOL_RESET_ON_RETURN': 'rollback',
        }
    },
    'read_replica': {
        'ENGINE': 'dj_db_conn_pool.backends.postgresql',
        'HOST': secrets["stag_postgres_DbHost"],
        'NAME': 's1_healthapi',
        'USER': secrets["stag_postgres_DbUser"],
        'PASSWORD': secrets["stag_postgres_DbPswd"],
        'CONN_MAX_AGE': 0,
        'OPTIONS': {'sslmode': 'require'},
        'POOL_OPTIONS': {
            'POOL_SIZE': 3,
            'MAX_OVERFLOW': 2,
            'RECYCLE': 300,
            'PRE_PING': True,
            'POOL_TIMEOUT': 3,
            'POOL_RESET_ON_RETURN': 'rollback',
        }
    }
}
##########################################################################
# Redis Cache
CACHES = {
    'default': {
        'BACKEND': "django_redis.cache.RedisCache",
        'LOCATION': 'redis://redis:6379/2',
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient'
        }
    },
    "scheduler": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": "redis://redis:6379/16",
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
            "SERIALIZER": "django_redis.serializers.json.JSONSerializer",
        },
        "KEY_FUNCTION": "helpers.cache_adapter.schedular_key_maker",
    }
}
##########################################################################
# Sentry Config
sentry_sdk.init(
    dsn='https://dc2dbba4efd04d948a4bd1b4f9d8b143@o397714.ingest.sentry.io/5305383',
    integrations=[
        DjangoIntegration(),
        RedisIntegration(),
        CeleryIntegration()],
    # If you wish to associate users to errors (assuming you are using
    # django.contrib.auth) you may enable sending PII data.
    send_default_pii=True
)
##########################################################################
# Token Config
TOKEN_CONFIG = {
    'SECRET_KEY': 'MASKED_SECRETdUc=',
    'ALGORITHM': 'HS256'
}
##########################################################################
# S3 Creds
AWS_ACCESS_KEY = secrets["stag_awsAccessKeyId"]
AWS_SECRET_KEY = secrets["stag_awsSecretAccessKey"]
AWS_BUCKET = 's1-oh-media'
PRIVATE_S3_BUCKET = 's1-oms-orders'
##########################################################################
# Celery config
CELERY['BROKER_TRANSPORT_OPTIONS']['region'] = 'ap-south-1'
CELERY['BROKER_TRANSPORT_OPTIONS']['queue_name_prefix'] = 's1-health-'
CELERY['TASK_DEFAULT_QUEUE'] = 'test-queue'
SQS_ACCESS_KEY = secrets["stag_awsSqsAccessKeyId"]
SQS_SECRET_KEY = secrets["stag_awsSqsSecretAccessKey"]
SQS_URL = 'sqs.ap-south-1.amazonaws.com/267224240039/'
CELERY['BROKER_URL'] = "sqs://{access_key}:{secret_key}@{sqs_url}".format(
    access_key=SQS_ACCESS_KEY,
    secret_key=urllib.parse.quote_plus(SQS_SECRET_KEY),
    sqs_url=SQS_URL,
)
# # Celery config
CELERY['CELERY_RESULT_BACKEND'] = None
##########################################################################
# Accounts Microservice creds
ACCOUNTS_SETTINGS['SECRET_KEY'] = 'e1D3y3MsJCUSvP4OarloXCvl'
ACCOUNTS_SETTINGS['BASE_URL'] = 'http://accounts-api/'
##########################################################################
# Scheduler Microservice creds
SCHEDULER_SETTINGS['SECRET_KEY'] = 'V89Co10c4vdSuDa52q9LiQbp'
SCHEDULER_SETTINGS['BASE_URL'] = 'https://scheduler-api:8010/'
##########################################################################
# GeoMark Microservice creds
GEOMARK_SETTINGS['SECRET_KEY'] = '5e7LiT7366AmSIi1mxxeYRXo'
GEOMARK_SETTINGS['BASE_URL'] = 'http://geomark-api/api/'
##########################################################################
# S3Wrapper Microservice creds
S3WRAPPER_SETTINGS['SECRET_KEY'] = '5U1nnY14Kr6sMSRT6XxT1qBG'
S3WRAPPER_SETTINGS['BASE_URL'] = 'https://s1-files.orangehealth.dev'
##########################################################################
# Firebase Config + Chat Config
FIREBASE_STORAGE_BUCKET = 's1-f8eea.firebasestorage.app'
firebase_app = firebase_admin.initialize_app(cred, {
    'databaseURL': 'https://s1-f8eea-default-rtdb.firebaseio.com/',
    'storageBucket': FIREBASE_STORAGE_BUCKET
})
##########################################################################
# service keys
SERVICE_KEYS['ACCOUNTS']['SECRET_KEY'] = 'e1D3y3MsJCUSvP4OarloXCvl'
SERVICE_KEYS['CLR']['SECRET_KEY'] = "4b6Jmf71OxvPFRsuriez60KZ"
SERVICE_KEYS['FIREBASE_CLOUD']['SECRET_KEY'] = 'uy!m(y4p-y&t6vep@mxk+8@_h-v1+4^+66m$v$)m5%tlmw**j%'
SERVICE_KEYS['RETOOL']['SECRET_KEY'] = 'b)d!wcd7=if2vln14c90vvk^rkl^v=mdoa$1j$l_9swptivqkz'
SERVICE_KEYS['OMS']['SECRET_KEY'] = '+ny(*s-pn)zg2)99#fl*-8e^yps)t7ak&=r3$cs1hkcb-jk#e2'
SERVICE_KEYS['PARTNER_API']['SECRET_KEY'] = 'eL4JwCKSjFNxXxZ2t5CuqJ86Rz'
SERVICE_KEYS['SCHEDULER']['SECRET_KEY'] = 'V1y86Ec7jXizIS8gfYYuvPWs'
SERVICE_KEYS['OZONETEL']['USERNAME'] = 'orangehealth'
SERVICE_KEYS['OZONETEL']['API_KEY'] = 'KKe8dc37bbfe2ec422e98cd47edc5bfcb0'
SERVICE_KEYS['YM']['SECRET_KEY'] = '1s3nw^f$3#vwvlb^$=tw8xnenx$i%zf5$r0a7#0&_91d@6y=8!'
SERVICE_KEYS['FEEDBACK']['SECRET_KEY'] = 'VAKSEzOQ5PUSsj2T15J7S6xG'
SERVICE_KEYS['FRESHCHAT_RATING']['SECRET_KEY'] = 'Ka41dZDm9wlGkT8Xn8AUJ5ks'
SERVICE_KEYS['SHLINK']['SERVICE_URL'] = "https://s.orn.ge/rest/v3/short-urls"
SERVICE_KEYS['SHLINK']['API_KEY'] = 'abe4190c-7fb5-4c60-9062-77c54a6c7209'
SERVICE_KEYS['PAYMENT']['SECRET_KEY'] = 'w!4aao(rl1a^64u71h#57skg5g#g6&pc#hgdi+fguafv!jao+v'
SERVICE_KEYS['FRESHCHAT_CRM_AUTOMATION']['SECRET_KEY'] = "f6b5b1b0-0b1b-4b3b-8b1b-0b1b0b1b0b1b"
SERVICE_KEYS['WORD_PRESS']['SECRET_KEY'] = "9f649976-e665-4a40-96b2-41d6d5846342"
SERVICE_KEYS['CITADEL']['SECRET_KEY'] = "abcd"
SERVICE_KEYS['CONSENT_SERVICE']['SECRET_KEY'] = "consent-service-to-health-api-key"

try:
    SERVICE_KEYS['PATIENT']['SECRET_KEY'] = "+ny(*s-pn)zg2)99#fl*-8e^yps)t7ak&=r3$cs1hkcb-jk#e2"
except:
    pass
##########################################################################
# slack config
SLACK_CONFIG['API_TOKEN'] = 'MASKED_SLACK_TOKEN'
##########################################################################
WEB_BASE_URL = 'https://s1-web.orangehealth.dev'
##########################################################################
S3_BASE_URL = 'https://s1-media.orangehealth.dev'
##########################################################################
API_BASE_URL = 'https://s1-api.orangehealth.dev'
##########################################################################
ORDER_EMAIL_ADDRESS = 'rajendra@orangehealth.in'
ORDER_UPLOAD_ERROR_NOTIF_ADDRESS = 'rajendra@orangehealth.in'
DOCTOR_OP_NOTIF_EMAIL_ADDRESS = 'rajendra@orangehealth.in'
##########################################################################
VOIP_CONFIG['doctor']['APP_ID'] = 'efa87be8-f7a8-4f62-8776-4b1603f9d4ba'
VOIP_CONFIG['doctor']['API_KEY'] = 'MASKED_SECRETZTVjZWI4'
VOIP_CONFIG['customer']['APP_ID'] = '93afc081-6a09-44b3-89e1-2fed9f09dd14'
VOIP_CONFIG['customer']['API_KEY'] = 'MASKED_SECRETZjJmYzYw'
##########################################################################
# CORS settings only for dev/stag env
CORS_ORIGIN_ALLOW_ALL = True
##########################################################################
CUSTOM_ORDER_DOCTORS = '[351]'
##########################################################################
TEST_ACCOUNT_NUMBERS = ['8105458610', '8103232323', '8082249956', '9675762947', '9085850496',
                        '9113822981', '9971102333', '9953321353', '9945525498', '9945525498',
                        '8310517376', '9997071797',
                        '6362113238', '9964751132', '9008109357', '8885358109', '8126583671', '9591682304', '7892103791',
                        '9131090917']
##########################################################################
OMS_SETTINGS['BASE_URL'] = 'https://oms:8080'
OMS_SETTINGS['SECRET_KEY'] = 'cJEUKcQq9Dypf48N7T0E5hYi'
OMS_SETTINGS['S3_BUCKET_NAME'] = 's1-oms-orders'
OMS_SETTINGS['S3_ACCESS_KEY'] = secrets["stag_awsAccessKeyId"]
OMS_SETTINGS['S3_SECRET_KEY'] = secrets["stag_awsSqsSecretAccessKey"]
##########################################################################
OMS_ROUTER_SETTINGS['BASE_URL'] = 'http://oms:8080'
OMS_ROUTER_SETTINGS['SECRET_KEY'] = 'Sg27UZZhi2bSYuUhD5m0OFL5'
SALES_TEAM_EMAIL_ADDRESS = 'rajendra@orangehealth.in'
TIME_INTERVAL_FOR_DOCTOR_LEAD_EMAIL_SELF_SERVE = 3600
DOCTOR_SALES_TEAM_EMAIL_ADDRESS = "rajendra@orangehealth.in"
##########################################################################
CDP_SETTINGS["BASE_URL"] = "https://s1-cdp-api.orangehealth.dev"
CDP_SETTINGS["SECRET_KEY"] = "2FDYBBZqG2PWsZAY4pf20hf2"
CDP_SETTINGS["API_KEY"] = "2FDYBBZqG2PWsZAY4pf20hf2"
##########################################################################
CLR_SETTINGS['BASE_URL'] = "https://s1-clr-api.orangehealth.dev"
CLR_SETTINGS['SECRET_KEY'] = "4b6Jmf71OxvPFRsuriez60KZ"
CLR_SETTINGS['API_KEY'] = "uvpGoRd1bD7JHN1q1DiTaYO5"
##########################################################################
PARTNER_API_SETTINGS['BASE_URL'] = 'https://s1-partner-api.orangehealth.dev'
PARTNER_API_SETTINGS['SECRET_KEY'] = 'eL4JwCKSjFNxXxZ2t5CuqJ86Rz'
##########################################################################
PAYMENT_SETTINGS['BASE_URL'] = 'https://s1-payment-api.orangehealth.dev'
PAYMENT_SETTINGS['SECRET_KEY'] = 'w!4aao(rl1a^64u71h#57skg5g#g6&pc#hgdi+fguafv!jao+v'
##########################################################################
PATIENT_SETTINGS['BASE_URL'] = "http://patients-api/api"
PATIENT_SETTINGS['SECRET_KEY'] = "sdkvewlkjhvaweljhkv"
##########################################################################
FEEDBACK_SETTINGS["BASE_URL"] = "http://feedback-api"
##########################################################################
PARTNER_CONFIG['PARTNER_WITHDRAW_ENABLED'] = '1'
##########################################################################
LEAD_WEBHOOK_SECRETS['UNBOUNCE'] = '896A6fztxqip6DCcZRX1lGAy'
##########################################################################
DOCTOR_CONFIG['DOCTOR_ORDERS_ENABLED'] = '1'
##########################################################################
CLEVERTAP_SETTINGS['ACCOUNT_ID'] = 'TEST-675-44Z-Z96Z'
CLEVERTAP_SETTINGS['PASSCODE'] = '2d2d9036ce674417b67b7d8761f3c500'
CLEVERTAP_SETTINGS['DOCTOR)_ACCOUT_ID'] = ''
CLEVERTAP_SETTINGS['DOCTOR_PASSCODE'] = ''
##########################################################################
RECORDS_STORAGE_SERVICE = 'AWS'
##########################################################################
SERVICE_KEYS['SALES_FORM']['SECRET_KEY'] = 'mm4z6v79n9JN2N1JgvToIcgZ'
##########################################################################
PREVIOUSLY_BOOKED_UPDATE_FREQUENCY = '7'
##########################################################################
CDS_SETTINGS['SECRET_KEY'] = "MASKED_SECRETu4k6W98A"
CDS_SETTINGS['BASE_URL'] = "http://cds-api"
CDS_SETTINGS['DEFAULT_USER'] = "rajendra@orangehealth.in"
CDS_SETTINGS['SERVICE_NAME'] = "health"

CEREBRO_SETTINGS['BASE_URL'] = "https://s1-cerebro.orangehealth.dev"
CEREBRO_SETTINGS['SECRET_KEY'] = "Y4WEgs3kPHYGuphFbYr0fby66U8INjh8"
##########################################################################
STAG_PHC_BASE_URL = f"https://s1-www.orangehealth.dev/products/personalised-health-checkup/summary?id=<questionnaire_id>"
PROD_PHC_BASE_URL = "https://s1-www.orangehealth.dev/products/personalised-health-checkup/summary?id=<questionnaire_id>"
STAG_OMS_REQUEST_URL = f"https://s1-oms-<city_code>.orangehealth.dev/request/<oms_request_id>"
PROD_OMS_REQUEST_URL = "https://s1-oms-<city_code>.orangehealth.dev/request/<oms_request_id>"
##########################################################################
PHC_LEAD_DELAY = '1800'
##########################################################################
# Microservice Odin API creds
ODIN_SETTINGS["BASE_URL"] = 'https://s1-odin-api.orangehealth.dev'
ODIN_SETTINGS["SECRET_KEY"] = '9awLHJ7a7hEiOcDh0QZ2xtXz'
ODIN_SETTINGS["SYNC_BATCH_SIZE"] = '100'

# Feature flags
FEATURE_FLAGS['ODIN_SYNC'] = 'true'
SHORT_URL = "https://s.orn.ge/rest/v3/short-urls"


# Address settings
ADDRESS_MATCH_SETTINGS["MIN_SCORE"] = int(80)
ADDRESS_MATCH_SETTINGS["MAX_THRESHOLD"] = int(95)
ADDRESS_MATCH_SETTINGS["THRESHOLD_LEN"] = int(10)
ADDRESS_MATCH_SETTINGS["LAT_LON_DIFF"] = float(0.0009)
ADDRESS_MATCH_SETTINGS["LAT_LON_PREFIX_LEN"] = int(6)
ADDRESS_MATCH_SETTINGS["ALGO_VERSION"] = int(1)
ADDRESS_MATCH_SETTINGS["BATCH_SIZE"] = int(0)
ADDRESS_MATCH_SETTINGS["NAME_WEIGHTAGE"] = int('20')
ADDRESS_MATCH_SETTINGS["ADDRESS_WEIGHTAGE"] = int('80')

# Appflyer settings
OH_PATIENT_ANDROID_APPFLYER_APP_ID = 'in.orangehealth.patient'
OH_PATIENT_IOS_APPFLYER_APP_ID = 'id1534689588'
APPFLYER_AUTH = '9ouE4xoaffU2SVdj8yDpJc'
ZAPIER_URL_OFFLINE_CONVERSION = 'https://hooks.zapier.com/hooks/catch/12887569/37yqmsx'
ZAPIER_URL_PAID_CONVERSION = 'https://hooks.zapier.com/hooks/catch/abc/xyz/'

##########################################################################

IS_AUTOMATIC_PUBSUB_SETUP_ENABLED = "False"
# Pubsub Publisher settings
PUBLISH_TOPIC_SETTINGS = {
    "CONTACT_MERGE_CONFIRM": {
        "SOURCE": "health",
        "TOPIC_ARN": "arn:aws:sns:ap-south-1:267224240039:s1-contact-merge-confirm",
    }
}

# Pubsub Subscriber settings
SUBSCRIBE_EVENT_DETAILS = {
    "CONTACT_MERGE": {
        "TOPIC_ARN": "arn:aws:sns:ap-south-1:267224240039:s1-contact-merge-request",
    },
    "REPORT_HP_SYNC_COMPLETE": {
        "TOPIC_ARN": "arn:aws:sns:ap-south-1:267224240039:s1-groot-report-hp-sync-complete",
    },
    "DEFAULT_AMAZON_ADDRESS": {
        "TOPIC_ARN": "arn:aws:sns:ap-south-1:267224240039:s1-amazon-default-address",
    },
}
SUBSCRIPTION_QUEUE_URL = (
    "https://sqs.ap-south-1.amazonaws.com/267224240039/s1-health-consumer"
)
PUBSUB_REDIS_LOCATION = "redis://redis:6379/32"
PUBSUB_REDIS_MAX_CONNECTIONS = 10
SQS_CONSUMER_SLEEP_TIME = "5"
AWS_SNS_SQS_REGION = "ap-south-1"

##########################################################################

AWS_SNS_SQS_ACCESS_KEY = secrets["stag_awsSqsAccessKeyId"]
AWS_SNS_SQS_SECRET_KEY = secrets["stag_awsSqsSecretAccessKey"]
SNS_ENDPOINT_URL = None
SQS_ENDPOINT_URL = "https://sqs.ap-south-1.amazonaws.com/267224240039/"

##########################################################################
MEMBER_MATCH_SETTINGS = {
    "MATCH_THRESHOLD": 80
}
##########################################################################
MIXPANEL_PROJECT_TOKENS = {
    "D2C_WEB": "",
    "D2C_APP": "",
}

REST_FRAMEWORK = {
    'DEFAULT_THROTTLE_RATES': {
        'user': '100/min',
        'anon': '100/min',
        'payment_link': '10/min',
        'voucher': '20/min',
        'customer_email_view': '100/min',
        'sales_form': '20/min',
        "tests_search": "100/min",
        'generic_email': '3/min',
        'agent_visibility': '120/min',
        'occ_api': '60/min',
        'custom_anonymous': '5/min',
    },
    'EXCEPTION_HANDLER':
        'common.v1.custom_throttle_handler.custom_exception_handler',
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
}

SERVICE_KEYS['PAYMENT']['API_KEY'] = 'w!4aao(rl1a^64u71h#57skg5g#g6&pc#hgdi+fguafv!jao+v'


REST_FRAMEWORK_DEFAULT_RENDERER_CLASSES = [
    'rest_framework.renderers.JSONRenderer',
]
if DJANGO_ENV == 'dev':
    REST_FRAMEWORK_DEFAULT_RENDERER_CLASSES.append(
        'rest_framework.renderers.BrowsableAPIRenderer')

REST_FRAMEWORK.update(
    {'DEFAULT_RENDERER_CLASSES': REST_FRAMEWORK_DEFAULT_RENDERER_CLASSES})
CLINIC_FRONT_DESK_TOKEN = 'clinicfrontdesk'
##########################################################################
GROOT_SETTINGS["BASE_URL"] = "http://groot-api"
GROOT_SETTINGS["SECRET_KEY"] = "mynameisgroot"
GROOT_SETTINGS["SERVICE_NAME"] = "HEALTH"

##############################################################################
CONSENT_SERVICE_SETTINGS['BASE_URL'] = "http://consent-api"
CONSENT_SERVICE_SETTINGS['API_KEY'] = "health-api-to-consent-service-key"
CONSENT_SERVICE_SETTINGS['SERVICE_NAME'] = "HealthAPI"

##########################################################################
DOKUMENTOR_SETTINGS["BASE_URL"] = "http://dokumentor-api"
DOKUMENTOR_SETTINGS["API_KEY"] = "dokumentor-healthapi-key"

##########################################################################
# Camp Configuration
CAMP_CONFIG = {
    'DEFAULT_MAX_SLOT_CAPACITY': 25,
    'DEFAULT_SLOT_START_HOUR': 8,  # 8 AM
    'DEFAULT_SLOT_END_HOUR': 14,   # 2 PM (generates slots till 1-2 PM)
    'DEFAULT_SLOT_START_MINUTE': 0,  # Start at :00
    'SLOT_DURATION_MINUTES': 60,
    'CAMP_SPECIFIC_CONFIG': {
        'BLR5009': {
            'MAX_SLOT_CAPACITY': 3,
            'SLOT_START_HOUR': 8,
            'SLOT_START_MINUTE': 30,  # Start at 8:30 AM
            'SLOT_END_HOUR': 16,  # 4 PM
            'SLOT_END_MINUTE': 30,  # End at 4:30 PM
        }
    }
}


CAMP_SLOTS_ENABLED = [
    "BLR5009",
]