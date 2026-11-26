from django.urls import path
from . import billing_api as a
urlpatterns = [
    path('billing/plans/', a.plans),
    path('billing/subscription/', a.my_subscription),
    path('billing/subscription/<int:pk>/cancel/', a.cancel_pending),
    path('billing/points/', a.my_points),
    path('admin/billing/plans/', a.admin_plans),
    path('admin/billing/plans/<str:code>/', a.admin_plan),
    path('admin/billing/subscriptions/', a.admin_subscriptions),
    path('admin/billing/subscriptions/<int:pk>/', a.admin_subscription),
    path('admin/billing/wallets/', a.admin_wallets),
    path('admin/billing/wallets/<int:pk>/', a.admin_wallet),
]
