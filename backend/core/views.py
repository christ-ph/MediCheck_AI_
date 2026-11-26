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
    s = Registration(data=request.data)
    s.is_valid(raise_exception=True)
    d = s.validated_data.copy()
    if d.pop('professional_requested', False):
        raise serializers.ValidationError('Créez un compte usager puis déposez un dossier professionnel.')
    with transaction.atomic():
        u = User.objects.create_user(**d)
        Profile.objects.create(user=u)
    return Response({'username': u.username}, status=201)
@api_view(['GET'])
def me(request):
    return Response(profile_info(request.user))
class MedicineSerializer(serializers.ModelSerializer):
    reference = serializers.SerializerMethodField()

    def get_reference(self, obj):
        from .intelligence_api import reference_data
        ref = getattr(obj, "reference", None)
        return reference_data(ref) if ref and obj.published else None

    class Meta:
        model=Medicine; fields=['id','name','description','source','reference']
        
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
    def perform_create(self, s):
        from django.db import IntegrityError, OperationalError
        from rest_framework.exceptions import PermissionDenied, APIException
        from .duplicate_api import find_duplicate, reject_duplicate
        name, source = s.validated_data['name'], s.validated_data['source']
        try:
            with transaction.atomic():
                Profile.objects.select_for_update().filter(user=self.request.user).first()
                if not profile_info(self.request.user)['professional_verified']:
                    raise PermissionDenied('Compte professionnel non validé.')
                duplicate = find_duplicate(name, source)
                if duplicate:
                    reject_duplicate(duplicate)
                medicine = s.save(author=self.request.user, published=False)
                from .review_service import create_cycle
                create_cycle(medicine)
        except IntegrityError:
            duplicate = find_duplicate(name, source)
            if duplicate:
                reject_duplicate(duplicate)
            raise
        except OperationalError as exc:
            if 'locked' not in str(exc).lower():
                raise
            error = APIException('Base temporairement occupée. Veuillez réessayer.')
            error.status_code = 503
            raise error from exc
class ReportSerializer(serializers.ModelSerializer):
    class Meta:
        model=Report; fields=['id','medicine','kind','details']
class Reports(generics.ListCreateAPIView):
    serializer_class=ReportSerializer
    def get_queryset(self): return Report.objects.filter(user=self.request.user).order_by('-created')
    def perform_create(self,s): s.save(user=self.request.user)

from .professional_api import profile_info, apply_professional
