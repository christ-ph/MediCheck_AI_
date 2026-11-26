from django.contrib import admin
from django.urls import path
from rest_framework_simplejwt.views import TokenObtainPairView,TokenRefreshView
from core import views
urlpatterns=[path('admin/',admin.site.urls),path('api/register/',views.register),path('api/token/',TokenObtainPairView.as_view()),path('api/token/refresh/',TokenRefreshView.as_view()),path('api/me/',views.me),path('api/medicines/',views.Catalog.as_view()),path('api/proposals/',views.Proposal.as_view()),path('api/reports/',views.Reports.as_view())]

# Portail React MediCheck
from django.urls import include
urlpatterns += [path('api/admin/', include('core.admin_urls'))]

urlpatterns += [path('api/professional/application/', views.apply_professional)]

from django.urls import include
urlpatterns += [path('api/', include('core.billing_urls'))]

from django.urls import include
urlpatterns += [path('api/', include('core.review_urls'))]

from django.urls import include
urlpatterns += [path('api/', include('core.intelligence_urls'))]

# Render health check
from django.http import JsonResponse
from django.db import connection, DatabaseError

def health(request):
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
    except DatabaseError:
        return JsonResponse({"status": "unavailable"}, status=503)
    return JsonResponse({"status": "ok", "service": "MediCheck AI"})

urlpatterns += [path("health/", health)]
