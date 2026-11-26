from django.conf import settings
from django.db import models
from django.db.models import Q


class ReviewCycle(models.Model):
    medicine = models.ForeignKey('core.Medicine', on_delete=models.PROTECT, related_name='review_cycles')
    number = models.PositiveIntegerField(default=1)
    name = models.CharField(max_length=200)
    description = models.TextField()
    source = models.URLField()
    status = models.CharField(max_length=16, default='waiting', choices=[(x,x) for x in ('waiting','reviewing','published','revision')])
    reason = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    closed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['medicine','number'], name='unique_medicine_review_cycle'),
                       models.UniqueConstraint(fields=['medicine'], condition=Q(status__in=['waiting','reviewing']), name='one_open_review_cycle')]


class ReviewAssignment(models.Model):
    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT, related_name='assignments')
    reviewer = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name='medicine_assignments')
    state = models.CharField(max_length=12, default='pending', choices=[(x,x) for x in ('pending','voted','cancelled')])
    decision = models.CharField(max_length=10, blank=True, choices=[('approve','Approuver'),('reject','Rejeter')])
    comment = models.TextField(blank=True)
    checks = models.JSONField(default=dict)
    assigned_at = models.DateTimeField(auto_now_add=True)
    voted_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['cycle','reviewer'], name='one_vote_per_cycle_reviewer')]


class ReviewNotification(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='review_notifications')
    cycle = models.ForeignKey(ReviewCycle, on_delete=models.PROTECT, null=True, blank=True)
    category = models.CharField(max_length=16, default='review', choices=[('review','Validation médicale'),('subscription','Abonnement'),('professional','Dossier professionnel')])
    subscription = models.ForeignKey('core.Subscription', on_delete=models.PROTECT, null=True, blank=True)
    message = models.CharField(max_length=500)
    created_at = models.DateTimeField(auto_now_add=True)
    read_at = models.DateTimeField(null=True, blank=True)
