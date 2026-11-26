from django.db import models
from django.conf import settings
class Profile(models.Model):
    user=models.OneToOneField(settings.AUTH_USER_MODEL,on_delete=models.CASCADE)
    professional_requested=models.BooleanField(default=False)
    professional_verified=models.BooleanField(default=False)
class Medicine(models.Model):
    name=models.CharField(max_length=200)
    description=models.TextField()
    source=models.URLField()
    published=models.BooleanField(default=False)
    author=models.ForeignKey(settings.AUTH_USER_MODEL,on_delete=models.PROTECT)

    identity_key = models.CharField(max_length=64, unique=True, editable=False)
    official_cis = models.CharField(max_length=8, unique=True, null=True, blank=True, editable=False)

    def save(self, *args, **kwargs):
        from .medicine_identity import name_key, official_cis
        fields = kwargs.get('update_fields')
        if fields is not None:
            fields = set(fields)
        if fields is None or 'name' in fields:
            self.identity_key = name_key(self.name)
            if fields is not None: fields.add('identity_key')
        if fields is None or 'source' in fields:
            self.official_cis = official_cis(self.source)
            if fields is not None: fields.add('official_cis')
        if fields is not None: kwargs['update_fields'] = fields
        return super().save(*args, **kwargs)

    def clean(self):
        from django.core.exceptions import ValidationError
        from .duplicate_api import find_duplicate
        super().clean()
        if find_duplicate(self.name, self.source, exclude=self.pk):
            raise ValidationError('Une fiche correspondante existe déjà dans le catalogue ou les propositions.')
class Report(models.Model):
    user=models.ForeignKey(settings.AUTH_USER_MODEL,on_delete=models.CASCADE)
    medicine=models.CharField(max_length=200)
    kind=models.CharField(max_length=20,choices=[('expired','Périmé'),('suspect','Suspect'),('adverse','Effet indésirable')])
    details=models.TextField()
    created=models.DateTimeField(auto_now_add=True)


class ProfessionalApplication(models.Model):
    class Status(models.TextChoices):
        PENDING = 'pending', 'En attente'
        APPROVED = 'approved', 'Validé'
        REJECTED = 'rejected', 'Refusé'
        REVOKED = 'revoked', 'Révoqué'

    profile = models.OneToOneField(Profile, on_delete=models.CASCADE, related_name='application')
    full_name = models.CharField(max_length=180)
    profession = models.CharField(max_length=100)
    registration_number = models.CharField(max_length=100)
    issuer = models.CharField(max_length=180)
    institution = models.CharField(max_length=180)
    location = models.CharField(max_length=180)
    phone = models.CharField(max_length=40)
    proof = models.BinaryField(editable=False)
    proof_type = models.CharField(max_length=40)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)
    reason = models.CharField(max_length=500, blank=True)
    submitted_at = models.DateTimeField(auto_now=True)
    reviewed_at = models.DateTimeField(null=True, blank=True)
    reviewed_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name='reviewed_professional_applications')


from .billing_models import SubscriptionPlan, Subscription, PointWallet, PointTransaction

from .review_models import ReviewCycle, ReviewAssignment, ReviewNotification

from .reference_models import MedicineReference, MedicinePresentation
