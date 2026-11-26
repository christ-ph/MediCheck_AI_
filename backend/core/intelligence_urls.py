from django.urls import path
from . import intelligence_api as api
urlpatterns=[path('intelligence/verify/',api.verify),path('intelligence/ocr/',api.ocr),path('intelligence/chat/',api.chat),path('intelligence/reference/<int:pk>/',api.reference)]

