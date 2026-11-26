from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from rest_framework.test import APITestCase
from .models import Medicine, Profile, ProfessionalApplication
from .medicine_identity import name_key, official_cis


class DuplicateTests(APITestCase):
    def setUp(self):
        U = get_user_model()
        self.pro = U.objects.create_user(username='duplicate-pro')
        p = Profile.objects.create(user=self.pro, professional_requested=True, professional_verified=True)
        ProfessionalApplication.objects.create(profile=p, status='approved', proof=b'%PDF-test')
        self.user = U.objects.create_user(username='duplicate-user')
        self.client.force_authenticate(self.pro)
        self.data = {'name': 'Paracétamol 500 mg', 'description': 'Fiche fictive de test', 'source': 'https://example.org/reference'}

    def submit(self, **changes):
        return self.client.post('/api/proposals/', {**self.data, **changes}, format='json')

    def test_published_duplicate(self):
        Medicine.objects.create(**self.data, author=self.pro, published=True)
        r = self.submit(name=' PARACETAMOL  500 MG ')
        self.assertEqual(r.status_code, 409)
        self.assertIn('catalogue', str(r.data['detail']))
        self.assertEqual(Medicine.objects.count(), 1)

    def test_pending_duplicate_and_distinct_dose(self):
        self.assertEqual(self.submit().status_code, 201)
        self.assertEqual(self.submit(name='paracetamol 500 mg').status_code, 409)
        self.assertEqual(self.submit(name='Paracétamol 1000 mg').status_code, 201)
        self.assertEqual(Medicine.objects.filter(published=False).count(), 2)

    def test_cis(self):
        base = 'https://base-donnees-publique.medicaments.gouv.fr/medicament/12345678/'
        self.assertEqual(self.submit(source=base+'extrait').status_code, 201)
        self.assertEqual(self.submit(name='Autre nom de test', source=base+'notice').status_code, 409)
        self.assertIsNone(official_cis('https://example.org/medicament/12345678/extrait'))

    def test_permission_and_constraint(self):
        Medicine.objects.create(**self.data, author=self.pro)
        self.client.force_authenticate(self.user)
        self.assertEqual(self.submit().status_code, 403)
        with self.assertRaises(IntegrityError), transaction.atomic():
            Medicine.objects.create(**{**self.data, 'name': 'PARACETAMOL 500 MG'}, author=self.pro)
        self.assertEqual(name_key('A 1,5 mg'), name_key('a 1,5 mg'))
        self.assertNotEqual(name_key('A 1,5 mg'), name_key('A 15 mg'))
