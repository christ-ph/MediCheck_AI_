from django.contrib.auth.models import User
from .pagination import MedicinePagination
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.db import transaction
from rest_framework import serializers, generics
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from .models import Profile, Medicine, Report
class Registration(serializers.Serializer):
    username=serializers.CharField(max_length=150)
    email=serializers.EmailField()
    password=serializers.CharField(write_only=True)
    professional_requested=serializers.BooleanField(default=False)
    def validate(self,d):
        if User.objects.filter(username=d['username']).exists(): raise serializers.ValidationError('Identifiant déjà utilisé.')
        try: validate_password(d['password'])
        except ValidationError as e: raise serializers.ValidationError(e.messages)
        return d
@api_view(['POST'])
@permission_classes([AllowAny])
def register(request):
    s=Registration(data=request.data); s.is_valid(raise_exception=True)
    d=s.validated_data.copy(); pro=d.pop('professional_requested')
    with transaction.atomic():
        u=User.objects.create_user(**d); Profile.objects.create(user=u,professional_requested=pro)
    return Response({'username':u.username},status=201)
@api_view(['GET'])
def me(request):
    p,_=Profile.objects.get_or_create(user=request.user)
    return Response({'username':request.user.username,'professional_verified':p.professional_verified})
class MedicineSerializer(serializers.ModelSerializer):
    class Meta:
        model=Medicine; fields=['id','name','description','source']
        
class Catalog(generics.ListAPIView):

    serializer_class = MedicineSerializer

    pagination_class = MedicinePagination

    def get_queryset(self):

        query = self.request.query_params.get(
            "q", ""
        ).strip()

        return Medicine.objects.filter(
            published=True,
            name__icontains=query
        ).order_by("name", "id")
    
class Proposal(generics.CreateAPIView):
    serializer_class=MedicineSerializer
    def perform_create(self,s):
        from rest_framework.exceptions import PermissionDenied
        if not Profile.objects.filter(user=self.request.user,professional_verified=True).exists(): raise PermissionDenied('Compte professionnel non validé.')
        s.save(author=self.request.user,published=False)
class ReportSerializer(serializers.ModelSerializer):
    class Meta:
        model=Report; fields=['id','medicine','kind','details']
class Reports(generics.ListCreateAPIView):
    serializer_class=ReportSerializer
    def get_queryset(self): return Report.objects.filter(user=self.request.user).order_by('-created')
    def perform_create(self,s): s.save(user=self.request.user)
