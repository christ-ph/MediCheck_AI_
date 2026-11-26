from django.urls import path
from . import admin_api as a
urlpatterns = [
    path('overview/', a.overview),
    path('professionals/', a.professionals),
    path('professionals/<int:pk>/', a.verify_professional),
    path('users/', a.users),
    path('users/<int:pk>/', a.account_status),
    path('medicines/', a.medicines),
    path('reports/', a.reports),
]
