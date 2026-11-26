from .settings import *  # noqa: F401,F403
import os
import dj_database_url


def env_list(name):
    return [v.strip() for v in os.getenv(name, '').split(',') if v.strip()]


DEBUG = False
SECRET_KEY = os.environ['DJANGO_SECRET_KEY']
ALLOWED_HOSTS = list(dict.fromkeys(env_list('DJANGO_ALLOWED_HOSTS') + ['localhost', '127.0.0.1'] + ([os.environ['RENDER_EXTERNAL_HOSTNAME']] if os.getenv('RENDER_EXTERNAL_HOSTNAME') else [])))
DATABASES = {'default': dj_database_url.parse(os.environ['DATABASE_URL'], conn_max_age=60, conn_health_checks=True)}
CORS_ALLOWED_ORIGINS = env_list('CORS_ALLOWED_ORIGINS')
CORS_ALLOW_ALL_ORIGINS = False
CSRF_TRUSTED_ORIGINS = env_list('CSRF_TRUSTED_ORIGINS')
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
MIDDLEWARE = list(MIDDLEWARE)
MIDDLEWARE.insert(MIDDLEWARE.index('django.middleware.security.SecurityMiddleware') + 1, 'whitenoise.middleware.WhiteNoiseMiddleware')
STORAGES = {
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {'BACKEND': 'whitenoise.storage.CompressedManifestStaticFilesStorage'},
}
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_HSTS_SECONDS = 3600
SECURE_SSL_REDIRECT = True
# Allow internal health probes without redirects; no private data is returned.
SECURE_REDIRECT_EXEMPT = [r'^health/$']
X_FRAME_OPTIONS = 'DENY'
if 'django.middleware.clickjacking.XFrameOptionsMiddleware' not in MIDDLEWARE:
    MIDDLEWARE.append('django.middleware.clickjacking.XFrameOptionsMiddleware')
