from datetime import date,timedelta
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase
from .models import Medicine, MedicineReference, MedicinePresentation
from .intelligence_api import code_from

class IntelligenceTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.user=get_user_model().objects.create_user(username='intelligence-test')
        self.client.force_authenticate(self.user)
        self.med=Medicine.objects.create(author=self.user,name='Exemple unique 25 mg',description='Démonstration fictive',source='https://base-donnees-publique.medicaments.gouv.fr/medicament/12345678/extrait',published=True)
        self.ref=MedicineReference.objects.create(medicine=self.med,cis="12345678",official_name=self.med.name,components=[{'substance':'Exemple','strength':'25 mg','basis':'par unité'}])
        MedicinePresentation.objects.create(reference=self.ref,cip13='3400000000001',cip7='1234567',label='Boîte test')
    def test_codes(self):
        self.assertEqual(code_from('(01)03400000000001(17)301201'),'3400000000001')
        self.assertEqual(code_from('3400000000001'),'3400000000001')
        self.assertEqual(code_from('https://example.org'),'')
    def test_verify_and_unpublished(self):
        r=self.client.post('/api/intelligence/verify/',{'code':'3400000000001','expiry':str(timezone.localdate()-timedelta(days=1))},format='json')
        self.assertEqual(r.status_code,200,r.data);self.assertEqual(r.data['status'],'code_found');self.assertEqual(r.data['expiry'],'expired')
        self.med.published=False;self.med.save(update_fields=['published'])
        r=self.client.post('/api/intelligence/verify/',{'code':'3400000000001'},format='json');self.assertEqual(r.data['status'],'not_found')
        self.assertEqual(self.client.get(f'/api/intelligence/reference/{self.med.pk}/').status_code,404)
    def test_chat_retrieval(self):
        r=self.client.post('/api/intelligence/chat/',{'question':'Composition Exemple unique','external':False},format='json');self.assertEqual(r.status_code,200);self.assertEqual(r.data['mode'],'retrieval');self.assertIn('25 mg',r.data['answer'])
        r=self.client.post('/api/intelligence/chat/',{'question':'zzzzzz','external':False},format='json');self.assertEqual(r.data['mode'],'no_source')
    def test_permissions_and_invalid_ocr(self):
        self.assertEqual(self.client.post('/api/intelligence/ocr/',{'image':'not base64'},format='json').status_code,400)
        self.client.force_authenticate(None)
        self.assertIn(self.client.post('/api/intelligence/verify/',{'code':'3400000000001'},format='json').status_code,[401,403])

