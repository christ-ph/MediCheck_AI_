from django.urls import path
from . import review_api as a
urlpatterns=[
    path('reviews/inbox/',a.inbox), path('reviews/inbox/<int:pk>/vote/',a.vote),
    path('reviews/mine/',a.mine), path('reviews/mine/<int:pk>/revise/',a.revise),
    path('reviews/notifications/',a.notifications), path('reviews/notifications/<int:pk>/read/',a.mark_read),
    path('admin/reviews/',a.admin_cycles), path('admin/reviews/sync/',a.admin_sync),
]
