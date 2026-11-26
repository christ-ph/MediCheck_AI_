from django.db import models

class MedicineReference(models.Model):
    medicine = models.OneToOneField('core.Medicine', on_delete=models.CASCADE, related_name='reference')
    cis = models.CharField(max_length=8, unique=True)
    official_name = models.TextField()
    form = models.TextField(blank=True)
    route = models.TextField(blank=True)
    holder = models.TextField(blank=True)
    authorization = models.TextField(blank=True)
    market = models.TextField(blank=True)
    components = models.JSONField(default=list)
    prescription = models.JSONField(default=list)
    imported_at = models.DateTimeField(auto_now=True)

class MedicinePresentation(models.Model):
    reference = models.ForeignKey(MedicineReference, on_delete=models.CASCADE, related_name='presentations')
    cip13 = models.CharField(max_length=13, unique=True)
    cip7 = models.CharField(max_length=7, blank=True)
    label = models.TextField()
    market = models.TextField(blank=True)

