from django.conf import settings
from django.db import models
from django.db.models import Q


class SubscriptionPlan(models.Model):
    code = models.CharField(max_length=12, primary_key=True)
    name = models.CharField(max_length=40)
    price_fcfa = models.PositiveIntegerField(default=0)
    duration_days = models.PositiveIntegerField(default=30)
    enabled = models.BooleanField(default=True)


class Subscription(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    plan = models.ForeignKey(SubscriptionPlan, on_delete=models.PROTECT)
    price_fcfa = models.PositiveIntegerField()
    duration_days = models.PositiveIntegerField()
    status = models.CharField(max_length=12, default='pending', choices=[(x,x) for x in ('pending','active','rejected','cancelled','expired')])
    requested_at = models.DateTimeField(auto_now_add=True)
    starts_at = models.DateTimeField(null=True, blank=True)
    ends_at = models.DateTimeField(null=True, blank=True)
    decided_at = models.DateTimeField(null=True, blank=True)
    decided_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='subscription_decisions')
    reason = models.CharField(max_length=500, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['user'], condition=Q(status__in=['pending','active']), name='one_open_subscription')]


class PointWallet(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    balance = models.PositiveBigIntegerField(default=0)


class PointTransaction(models.Model):
    wallet = models.ForeignKey(PointWallet, on_delete=models.PROTECT, related_name='entries')
    delta = models.BigIntegerField()
    balance_after = models.PositiveBigIntegerField()
    reason = models.CharField(max_length=500)
    actor = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name='point_adjustments')
    operation_id = models.UUIDField(unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
