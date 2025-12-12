# Health Check Endpoint for Django
# Add this to your health-api/app/urls.py

from django.http import JsonResponse
from django.db import connection
from django.core.cache import cache
import time

def health_check(request):
    """
    Health check endpoint that verifies:
    - API is responding
    - Database connection is working
    - Cache connection is working (if configured)
    """
    start_time = time.time()
    health_status = {
        "status": "healthy",
        "timestamp": time.time(),
        "checks": {}
    }

    # Check database connection
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        health_status["checks"]["database"] = "ok"
    except Exception as e:
        health_status["status"] = "unhealthy"
        health_status["checks"]["database"] = f"error: {str(e)}"

    # Check cache connection (optional - comment out if not using cache)
    try:
        cache.set('health_check', 'ok', 10)
        cache_value = cache.get('health_check')
        health_status["checks"]["cache"] = "ok" if cache_value == 'ok' else "degraded"
    except Exception as e:
        health_status["checks"]["cache"] = f"error: {str(e)}"

    # Add response time
    health_status["response_time_ms"] = round((time.time() - start_time) * 1000, 2)

    status_code = 200 if health_status["status"] == "healthy" else 503
    return JsonResponse(health_status, status=status_code)


def readiness_check(request):
    """
    Readiness check endpoint - returns 200 when service is ready to accept traffic
    """
    return JsonResponse({"status": "ready"}, status=200)


def liveness_check(request):
    """
    Liveness check endpoint - returns 200 when service is alive
    """
    return JsonResponse({"status": "alive"}, status=200)


# Add these to your urls.py:
# from .views import health_check, readiness_check, liveness_check
#
# urlpatterns = [
#     path('health/', health_check, name='health_check'),
#     path('health/ready', readiness_check, name='readiness_check'),
#     path('health/live', liveness_check, name='liveness_check'),
#     # ... your other urls
# ]
