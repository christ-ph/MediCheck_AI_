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
class Report(models.Model):
    user=models.ForeignKey(settings.AUTH_USER_MODEL,on_delete=models.CASCADE)
    medicine=models.CharField(max_length=200)
    kind=models.CharField(max_length=20,choices=[('expired','Périmé'),('suspect','Suspect'),('adverse','Effet indésirable')])
    details=models.TextField()
    created=models.DateTimeField(auto_now_add=True)
